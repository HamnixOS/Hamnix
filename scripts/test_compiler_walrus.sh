#!/usr/bin/env bash
# scripts/test_compiler_walrus.sh — regression for the Adder walrus /
# assignment-expression `(name := value)`.
#
# Parser: `parse_primary` LPAREN branch (lookahead on IDENT WALRUS).
# Codegen: `codegen_x86.py`: `WalrusExpr` case + `_emit_local_store`.
#
# Adder is statically typed, so `name` MUST already be declared in
# scope. `:=` doesn't introduce a new binding — it strictly assigns
# and yields the value. Only the parenthesised form is accepted (a
# bare `:=` would shadow the statement-level `x = expr` recogniser).
#
# Strategy (host-side, no QEMU — pure codegen regression):
#   1. Compile tests/test_compiler_walrus.ad to x86_64 asm.
#   2. Assemble + link against a C driver asserting:
#        - value-yield  (the assigned value flows through expressions)
#        - while-drain  (the classic loop-condition use-case)
#        - if-branch    (compute-and-test idiom)
#        - single-eval  (RHS evaluates exactly once)
#        - bare         (whole-expression walrus has the right value).
#   3. Run; PASS iff the sentinel prints and the binary exits 0.
#
# PASS criterion: "[compiler_walrus] PASS" on stdout.

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

TAG="compiler_walrus"
FIXTURE="tests/test_compiler_walrus.ad"
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

echo "[$TAG] (2/3) Assemble + link against walrus driver"
cat > "$DRIVER" <<'EOF'
#include <stdio.h>
#include <stdint.h>

extern int64_t walrus_yields_value(int64_t seed);
extern int64_t walrus_while_drain(int64_t start);
extern int64_t walrus_if_branch(int64_t x);
extern int64_t walrus_calls_once(int64_t x);
extern int64_t walrus_calls_once_count(int64_t x);
extern int64_t walrus_bare(int64_t x);

static int fails = 0;

#define CHECK(call, want) do {                                    \
    int64_t _g = (call); int64_t _w = (int64_t)(want);            \
    if (_g != _w) {                                               \
        fprintf(stderr, "[compiler_walrus] FAIL: %s = %lld, "     \
                "expected %lld\n", #call,                         \
                (long long)_g, (long long)_w);                    \
        fails++;                                                  \
    }                                                             \
} while (0)

int main(void) {
    /* `(n := seed) + 1` -> seed + 1 */
    CHECK(walrus_yields_value(0),   1);
    CHECK(walrus_yields_value(7),   8);
    CHECK(walrus_yields_value(-1),  0);

    /* `while (n := _next_chunk()) > 0:` drains a queue. _next_chunk
     * decrements `_chunks_left` THEN returns the new value, so a queue
     * of `start` items takes `start` iterations to reach 0 (the loop
     * exits when n reads 0). For start=0 the first call returns 0 and
     * the loop never enters. For start=N>0 the body runs N times before
     * the call that yields 0 terminates it -> N-1 successful body
     * passes... no wait: start=5 yields 4,3,2,1,0 -> 4 iters. */
    CHECK(walrus_while_drain(0),    0);
    CHECK(walrus_while_drain(1),    0);   /* dec to 0, exit */
    CHECK(walrus_while_drain(5),    4);
    CHECK(walrus_while_drain(100),  99);

    /* `if (q := x*x) > 100: return q+1; else return q-1` */
    CHECK(walrus_if_branch(5),      24);   /* 25, false (25>100), 25-1=24 */
    CHECK(walrus_if_branch(10),     99);   /* 100, false (100>100), 100-1=99 */
    CHECK(walrus_if_branch(11),     122);  /* 121, true, 121+1=122 */
    CHECK(walrus_if_branch(20),     401);  /* 400, true, 400+1=401 */

    /* `(n := f(x)) + n` — Adder evaluates binop operands right-first
     * (vs. Python's left-first), so the RIGHT `n` is read BEFORE the
     * walrus assigns. The initial `n` (0) is what's added, plus the
     * value yielded by the walrus on the left. Either way `f` is
     * called exactly ONCE (the right operand is `n`, a plain read).
     * That single-eval property is the load-bearing claim. */
    CHECK(walrus_calls_once(3),       3);  /* 0 (old n) + 3 (walrus) */
    CHECK(walrus_calls_once(-7),     -7);  /* 0 + -7 */
    CHECK(walrus_calls_once_count(3), 1);  /* f called once */

    /* Bare walrus: `(n := x + 7)` */
    CHECK(walrus_bare(0),   7);
    CHECK(walrus_bare(5),  12);
    CHECK(walrus_bare(-7), 0);

    if (fails) {
        fprintf(stderr, "[compiler_walrus] FAIL: %d case(s)\n", fails);
        return 1;
    }
    printf("[compiler_walrus] PASS\n");
    return 0;
}
EOF

CC="${CC:-cc}"
"$CC" -no-pie -O0 "$ASM" "$DRIVER" -o "$BIN"

echo "[$TAG] (3/3) Run walrus value/loop/single-eval assertions"
"$BIN"
