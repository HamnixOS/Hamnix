#!/usr/bin/env bash
# scripts/test_compiler_bool_shortcircuit.sh — regression for the Adder
# x86_64 backend's logical `and`/`or` lowering (codegen_x86.py:
# gen_short_circuit).
#
# Bug: a compound condition joining two DIFFERENT comparison operators
# with `or`/`and` (e.g. `a == 0 or a != b`, `func() <= 0 or x != y`)
# was lowered to an unconditional bitwise fold of BOTH operands — no
# short-circuit, right-before-left order. That can take the wrong branch
# / call the right operand when it should be skipped, which is why
# splitting the condition into two separate `if`s behaved differently.
#
# Strategy (host-side, no QEMU — this is a pure codegen regression):
#   1. Compile tests/test_compiler_bool_shortcircuit.ad to x86_64 asm via
#      the real `--target=x86_64-adder-user` backend path.
#   2. Assemble + link it against a C driver that:
#        - drives each boolean function with known runtime values,
#        - asserts the returned 0/1 against a hand-computed Python-style
#          truth table, and
#        - provides a `boom()` extern that abort()s if ever called,
#          proving `or`/`and` genuinely short-circuit the right operand.
#   3. Run the linked binary; PASS iff it prints the sentinel and exits 0.
#
# PASS criterion: "[compiler_bool_shortcircuit] PASS" on stdout.

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

TAG="compiler_bool_shortcircuit"
FIXTURE="tests/test_compiler_bool_shortcircuit.ad"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

ASM="$WORK/fixture.s"
DRIVER="$WORK/driver.c"
BIN="$WORK/run"

echo "[$TAG] (1/3) Compile $FIXTURE -> asm via x86_64 backend"
python3 -m compiler.adder asm \
    --target=x86_64-adder-user \
    "$FIXTURE" \
    -o "$ASM"

echo "[$TAG] (2/3) Assemble + link against truth-table driver"
cat > "$DRIVER" <<'EOF'
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>

extern long or_shortcircuit(long a);
extern long and_shortcircuit(long a);
extern long or_eq_neq(long a, long b);
extern long or_le_neq(long a, long b, long c);
extern long or_lt_ge(long a, long b, long c, long d);
extern long and_gt_neq(long a, long b, long c);
extern long nested_or_and(long a, long b, long c);
extern long three_or(long a, long b, long c);
extern long or_unsigned(unsigned long a, unsigned long b);

/* The right operand of a short-circuiting `or`/`and` must NOT run when
 * the left operand already decided the result. If it does, boom() fires
 * and we fail loudly. */
long boom(void) {
    fprintf(stderr, "[compiler_bool_shortcircuit] FAIL: boom() called "
                    "(right operand evaluated — no short-circuit)\n");
    exit(2);
    return 0;
}

static int fails = 0;
#define CHECK(call, expect) do {                                          \
    long _r = (call);                                                     \
    if (_r != (expect)) {                                                 \
        fprintf_failed(#call, _r, (long)(expect));                        \
    }                                                                     \
} while (0)

static void fprintf_failed(const char *what, long got, long want) {
    fprintf(stderr, "[compiler_bool_shortcircuit] FAIL: %s = %ld, "
                    "expected %ld\n", what, got, want);
    fails++;
}

int main(void) {
    /* --- short-circuit proofs (boom() aborts if wrongly evaluated) --- */
    CHECK(or_shortcircuit(5), 1);   /* a!=0 true  -> skip boom, true  */
    CHECK(and_shortcircuit(0), 0);  /* a!=0 false -> skip boom, false */

    /* --- or_eq_neq: (a==0) or (a!=b) --- */
    CHECK(or_eq_neq(12, 12), 0);    /* F or F = F  (the reported case) */
    CHECK(or_eq_neq(0, 0), 1);      /* T or F = T */
    CHECK(or_eq_neq(5, 7), 1);      /* F or T = T */
    CHECK(or_eq_neq(0, 3), 1);      /* T or T = T */

    /* --- or_le_neq: (a<=0) or (b!=c) --- */
    CHECK(or_le_neq(12, 5, 5), 0);  /* F or F = F  (the reported case) */
    CHECK(or_le_neq(12, 5, 6), 1);  /* F or T = T */
    CHECK(or_le_neq(0, 5, 5), 1);   /* T or F = T  (a<=0 boundary) */
    CHECK(or_le_neq(-3, 5, 5), 1);  /* T or F = T  (signed negative) */

    /* --- or_lt_ge: (a<b) or (c>=d) --- */
    CHECK(or_lt_ge(5, 5, 1, 2), 0); /* F or F = F */
    CHECK(or_lt_ge(1, 9, 1, 2), 1); /* T or F = T */
    CHECK(or_lt_ge(9, 1, 7, 2), 1); /* F or T = T */
    CHECK(or_lt_ge(-2, -1, 0, 9), 1); /* T or F = T (signed) */

    /* --- and_gt_neq: (a>0) and (b!=c) --- */
    CHECK(and_gt_neq(5, 1, 2), 1);  /* T and T = T */
    CHECK(and_gt_neq(5, 2, 2), 0);  /* T and F = F */
    CHECK(and_gt_neq(0, 1, 2), 0);  /* F and (skip) = F */
    CHECK(and_gt_neq(-1, 1, 2), 0); /* F and (skip) = F */

    /* --- nested_or_and: (a==0 or a!=b) and c>0 --- */
    CHECK(nested_or_and(12, 12, 5), 0); /* (F or F)=F, and T -> F */
    CHECK(nested_or_and(0, 0, 5), 1);   /* (T or F)=T, and T -> T */
    CHECK(nested_or_and(5, 7, 5), 1);   /* (F or T)=T, and T -> T */
    CHECK(nested_or_and(0, 0, 0), 0);   /* (T or F)=T, and F -> F */

    /* --- three_or: (a<0) or (b>=10) or (c!=0) --- */
    CHECK(three_or(5, 5, 0), 0);    /* F or F or F = F */
    CHECK(three_or(-1, 5, 0), 1);   /* T or ... = T */
    CHECK(three_or(5, 10, 0), 1);   /* F or T or ... = T */
    CHECK(three_or(5, 5, 9), 1);    /* F or F or T = T */

    /* --- or_unsigned: unsigned (a==0) or (a!=b) --- */
    CHECK(or_unsigned(12, 12), 0);  /* F or F = F */
    CHECK(or_unsigned(0, 0), 1);    /* T or F = T */
    CHECK(or_unsigned(5, 7), 1);    /* F or T = T */

    if (fails) {
        fprintf(stderr, "[compiler_bool_shortcircuit] FAIL: %d case(s)\n",
                fails);
        return 1;
    }
    printf("[compiler_bool_shortcircuit] PASS\n");
    return 0;
}
EOF

CC="${CC:-cc}"
"$CC" -no-pie -O0 "$ASM" "$DRIVER" -o "$BIN"

echo "[$TAG] (3/3) Run truth-table + short-circuit assertions"
"$BIN"
