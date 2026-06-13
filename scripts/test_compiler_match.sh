#!/usr/bin/env bash
# scripts/test_compiler_match.sh — regression for the Adder x86_64
# backend's `match`/`case` statement lowering (codegen_x86.py:
# _gen_match), plus the parser's pattern productions (parser.py:
# parse_pattern, _parse_or_alternative, _parse_sequence_pattern_tail).
#
# Strategy (host-side, no QEMU — pure compiler+codegen regression):
#   1. Compile tests/test_compiler_match.ad to x86_64 asm via the
#      real `--target=x86_64-adder-user` backend path.
#   2. Assemble + link against a C driver that drives each
#      pattern-shape function with known inputs and asserts the
#      returned dispatch code matches the Python-equivalent `match`
#      semantics. A `boom()` extern aborts if first-match-wins is
#      ever violated.
#   3. Run; PASS iff it prints the sentinel and exits 0.
#
# PASS criterion: "[compiler_match] PASS" on stdout.

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

TAG="compiler_match"
FIXTURE="tests/test_compiler_match.ad"
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

echo "[$TAG] (2/3) Assemble + link against dispatch-table driver"
cat > "$DRIVER" <<'EOF'
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>

extern long lit_or_default(long x);
extern long or_even_small(long x);
extern long name_binding(long x);
extern long guarded(long x);
extern long neg_literal(long x);
extern long first_match_wins(long x);
extern long seq_two(long *arr);
extern long seq_rest(long *arr);

/* boom() proves first-match-wins: if the wildcard arm fires when an
 * earlier literal arm matched, it aborts loudly. */
long boom(void) {
    fprintf(stderr, "[compiler_match] FAIL: boom() called "
                    "(later arm fired even though an earlier arm matched)\n");
    exit(2);
    return 0;
}

static int fails = 0;
static void fprintf_failed(const char *what, long got, long want) {
    fprintf(stderr, "[compiler_match] FAIL: %s = %ld, expected %ld\n",
            what, got, want);
    fails++;
}
#define CHECK(call, expect) do {                                          \
    long _r = (call);                                                     \
    if (_r != (expect)) fprintf_failed(#call, _r, (long)(expect));        \
} while (0)

int main(void) {
    /* --- literal + wildcard default --- */
    CHECK(lit_or_default(0), 10);
    CHECK(lit_or_default(1), 11);
    CHECK(lit_or_default(2), 12);
    CHECK(lit_or_default(3), 99);
    CHECK(lit_or_default(-7), 99);

    /* --- OR pattern --- */
    CHECK(or_even_small(2), 1);
    CHECK(or_even_small(4), 1);
    CHECK(or_even_small(6), 1);
    CHECK(or_even_small(1), 0);
    CHECK(or_even_small(8), 0);

    /* --- name binding (bound name equals scrutinee) --- */
    CHECK(name_binding(0), 1);
    CHECK(name_binding(41), 42);
    CHECK(name_binding(-5), -4);

    /* --- guard --- */
    CHECK(guarded(50), 0);     /* fails guard -> wildcard */
    CHECK(guarded(100), 0);    /* boundary: 100 > 100 is false */
    CHECK(guarded(101), 202);  /* fires */
    CHECK(guarded(200), 400);

    /* --- negative-int literal --- */
    CHECK(neg_literal(-1), 1);
    CHECK(neg_literal(0), 2);
    CHECK(neg_literal(7), 3);

    /* --- first match wins (boom aborts otherwise) --- */
    CHECK(first_match_wins(5), 50);

    /* --- sequence pattern over Array[2, int64] --- */
    long a12[2] = {1, 2};
    long a17[2] = {1, 7};
    long a99[2] = {9, 9};
    CHECK(seq_two(a12), 100);   /* [1, 2] */
    CHECK(seq_two(a17), 207);   /* [1, x]: 200 + 7 */
    CHECK(seq_two(a99), 0);     /* wildcard */

    /* --- sequence pattern with rest --- */
    long r0[3] = {0, 1, 2};
    long r1[3] = {1, 2, 3};
    CHECK(seq_rest(r0), 1);
    CHECK(seq_rest(r1), 0);

    if (fails) {
        fprintf(stderr, "[compiler_match] FAIL: %d case(s)\n", fails);
        return 1;
    }
    printf("[compiler_match] PASS\n");
    return 0;
}
EOF

CC="${CC:-cc}"
"$CC" -no-pie -O0 "$ASM" "$DRIVER" -o "$BIN"

echo "[$TAG] (3/3) Run dispatch + first-match assertions"
"$BIN"
