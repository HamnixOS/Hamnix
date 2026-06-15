#!/usr/bin/env bash
# scripts/test_compiler_augmented_assign.sh — regression for the Adder
# x86_64 backend's compound / augmented-assignment lowering
# (codegen_x86.py: gen_assignment + _COMPOUND_OP_MAP).
#
# Bug shape: LANGUAGE.md §17 promises ten compound operators
# (`+=  -=  *=  /=  %=  &=  |=  ^=  <<=  >>=`) on simple-identifier
# AND complex (`arr[i]`, `obj.f`) targets. The parser only allowed the
# five arithmetic ops on complex targets — `arr[i] >>= n`,
# `arr[i] |= mask`, etc. errored with "Unexpected token". The codegen
# path supported all ten ops uniformly; this is purely a parser
# carve-out fix, plus the previously-missing fixture LANGUAGE.md
# referenced by name.
#
# Strategy (host-side, no QEMU — pure codegen regression):
#   1. Compile tests/test_compiler_augmented_assign.ad to x86_64 asm via
#      the real `--target=x86_64-adder-user` backend path.
#   2. Assemble + link against a C driver that drives every helper
#      against a Python-evaluated reference (`%`, `/` follow Adder's
#      C-flavoured signed semantics; the table mirrors that).
#   3. Run; PASS iff the sentinel prints and the binary exits 0.
#
# PASS criterion: "[compiler_augmented_assign] PASS" on stdout.

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

TAG="compiler_augmented_assign"
FIXTURE="tests/test_compiler_augmented_assign.ad"
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

echo "[$TAG] (2/3) Assemble + link against compound-op driver"
cat > "$DRIVER" <<'EOF'
#include <stdio.h>
#include <stdint.h>

/* Identifier-target helpers */
extern int64_t aug_id_add(int64_t x, int64_t y);
extern int64_t aug_id_sub(int64_t x, int64_t y);
extern int64_t aug_id_mul(int64_t x, int64_t y);
extern int64_t aug_id_div(int64_t x, int64_t y);
extern int64_t aug_id_mod(int64_t x, int64_t y);
extern uint64_t aug_id_and(uint64_t x, uint64_t y);
extern uint64_t aug_id_or (uint64_t x, uint64_t y);
extern uint64_t aug_id_xor(uint64_t x, uint64_t y);
extern uint64_t aug_id_shl(uint64_t x, uint64_t n);
extern uint64_t aug_id_shr(uint64_t x, uint64_t n);

/* Index-target helpers */
extern int64_t aug_idx_add(int64_t s, int64_t r);
extern int64_t aug_idx_sub(int64_t s, int64_t r);
extern int64_t aug_idx_mul(int64_t s, int64_t r);
extern int64_t aug_idx_div(int64_t s, int64_t r);
extern int64_t aug_idx_mod(int64_t s, int64_t r);
extern uint64_t aug_idx_and(uint64_t s, uint64_t r);
extern uint64_t aug_idx_or (uint64_t s, uint64_t r);
extern uint64_t aug_idx_xor(uint64_t s, uint64_t r);
extern uint64_t aug_idx_shl(uint64_t s, uint64_t n);
extern uint64_t aug_idx_shr(uint64_t s, uint64_t n);

/* Single-eval proof */
extern int64_t aug_idx_single_eval(int64_t s, int64_t r);
extern int64_t aug_idx_single_eval_value(int64_t s, int64_t r);

static int fails = 0;

#define CHECK_S(call, want) do {                                       \
    int64_t _g = (call); int64_t _w = (int64_t)(want);                 \
    if (_g != _w) {                                                    \
        fprintf(stderr, "[" "compiler_augmented_assign" "] FAIL: %s = "\
                "%lld, expected %lld\n", #call,                        \
                (long long)_g, (long long)_w);                         \
        fails++;                                                       \
    }                                                                  \
} while (0)

#define CHECK_U(call, want) do {                                       \
    uint64_t _g = (call); uint64_t _w = (uint64_t)(want);              \
    if (_g != _w) {                                                    \
        fprintf(stderr, "[" "compiler_augmented_assign" "] FAIL: %s = "\
                "0x%llx, expected 0x%llx\n", #call,                    \
                (unsigned long long)_g, (unsigned long long)_w);       \
        fails++;                                                       \
    }                                                                  \
} while (0)

int main(void) {
    /* --- Identifier targets ------------------------------------ */
    CHECK_S(aug_id_add(10, 3), 13);
    CHECK_S(aug_id_add(-5, 8), 3);
    CHECK_S(aug_id_sub(10, 3), 7);
    CHECK_S(aug_id_sub(3, 10), -7);
    CHECK_S(aug_id_mul(6, 7), 42);
    CHECK_S(aug_id_mul(-4, 5), -20);
    CHECK_S(aug_id_div(20, 4), 5);
    CHECK_S(aug_id_div(-20, 4), -5);    /* signed */
    CHECK_S(aug_id_mod(23, 5), 3);
    CHECK_S(aug_id_mod(-23, 5), -3);    /* signed truncated */

    CHECK_U(aug_id_and(0xFFFFu, 0x0F0Fu), 0x0F0Fu);
    CHECK_U(aug_id_or (0xF000u, 0x000Fu), 0xF00Fu);
    CHECK_U(aug_id_xor(0xFF00u, 0x0FF0u), 0xF0F0u);
    CHECK_U(aug_id_shl(0x1u, 8), 0x100u);
    CHECK_U(aug_id_shl(0x12345678ull, 16), 0x123456780000ull);
    CHECK_U(aug_id_shr(0x100u, 4), 0x10u);
    CHECK_U(aug_id_shr(0xFFFFFFFFFFFFFFFFull, 60), 0xFull);

    /* --- IndexExpr targets (the parser-gap fix) ----------------- */
    CHECK_S(aug_idx_add(10, 3), 13);
    CHECK_S(aug_idx_add(-5, 8), 3);
    CHECK_S(aug_idx_sub(10, 3), 7);
    CHECK_S(aug_idx_mul(6, 7), 42);
    CHECK_S(aug_idx_div(20, 4), 5);
    CHECK_S(aug_idx_mod(23, 5), 3);

    CHECK_U(aug_idx_and(0xFFFFu, 0x0F0Fu), 0x0F0Fu);
    CHECK_U(aug_idx_or (0xF000u, 0x000Fu), 0xF00Fu);
    CHECK_U(aug_idx_xor(0xFF00u, 0x0FF0u), 0xF0F0u);
    CHECK_U(aug_idx_shl(0x1u, 8), 0x100u);
    CHECK_U(aug_idx_shl(0x12345678ull, 16), 0x123456780000ull);
    CHECK_U(aug_idx_shr(0x100u, 4), 0x10u);
    CHECK_U(aug_idx_shr(0xFFFFFFFFFFFFFFFFull, 60), 0xFull);

    /* --- single-evaluation proof (index is evaluated ONCE) ------ */
    /* counter == 1 means the index expr fired exactly once. */
    CHECK_S(aug_idx_single_eval(10, 3), 1);
    /* And the slot did get updated to 13. */
    CHECK_S(aug_idx_single_eval_value(10, 3), 13);

    if (fails) {
        fprintf(stderr, "[compiler_augmented_assign] FAIL: %d case(s)\n",
                fails);
        return 1;
    }
    printf("[compiler_augmented_assign] PASS\n");
    return 0;
}
EOF

CC="${CC:-cc}"
"$CC" -no-pie -O0 "$ASM" "$DRIVER" -o "$BIN"

echo "[$TAG] (3/3) Run compound-op truth table"
"$BIN"
