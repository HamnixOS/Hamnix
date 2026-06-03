#!/usr/bin/env bash
# scripts/test_compiler_sext_widen.sh — regression for the Adder x86_64
# backend's integer WIDENING lowering (codegen_x86.py: CastExpr case +
# _emit_cast_widen).
#
# Bug: widening a RUNTIME signed narrower integer to a wider one via
# `cast[int64](x)` zero-extended instead of sign-extending. A negative
# int32 like -1000 (0xFFFFFC18) widened to 0x00000000FFFFFC18 rather than
# the C-correct 0xFFFFFFFFFFFFFC18, corrupting every subsequent SIGNED
# int64 compare/arith. Only RUNTIME values were bitten (function returns,
# array elements, parameters, locals) — compile-time literals already
# sign-extended in their loader, masking the defect in literal-only tests.
#
# Strategy (host-side, no QEMU — a pure codegen regression):
#   1. Compile tests/test_compiler_sext_widen.ad to x86_64 asm via the
#      real `--target=x86_64-adder-user` backend path.
#   2. Assemble + link against a C driver that widens known negative AND
#      positive runtime narrow values to int64 and asserts the returned
#      64-bit pattern equals the C sign/zero-extended reference.
#   3. Run; PASS iff it prints the sentinel and exits 0.
#
# PASS criterion: "[compiler_sext_widen] PASS" on stdout.

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

TAG="compiler_sext_widen"
FIXTURE="tests/test_compiler_sext_widen.ad"
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

echo "[$TAG] (2/3) Assemble + link against sign-extension driver"
cat > "$DRIVER" <<'EOF'
#include <stdio.h>
#include <stdint.h>

/* All widen_* return the full 64-bit result; we inspect every bit. */
extern int64_t widen_ret_i32(int32_t x);
extern int64_t widen_param_i32(int32_t x);
extern int64_t widen_local_i32(int32_t x);
extern int64_t widen_array_i32(int32_t x);
extern int64_t widen_double_cast_i32(int32_t x);
extern int64_t widen_param_i16(int16_t x);
extern int64_t widen_param_i8(int8_t x);
extern int64_t widen_param_u32(uint32_t x);
extern int64_t widen_param_u16(uint16_t x);
extern int64_t widened_is_negative(int32_t x);

static int fails = 0;

static void check(const char *what, int64_t got, int64_t want) {
    if (got != want) {
        fprintf(stderr, "[compiler_sext_widen] FAIL: %s = 0x%016llx, "
                        "expected 0x%016llx\n",
                what, (unsigned long long)got, (unsigned long long)want);
        fails++;
    }
}

int main(void) {
    /* Signed int32 widen: the C reference sign-extends (the int64 cast). */
    check("widen_ret_i32(-1000)",   widen_ret_i32(-1000),   (int64_t)(int32_t)-1000);
    check("widen_ret_i32(1000)",    widen_ret_i32(1000),    (int64_t)(int32_t)1000);
    check("widen_ret_i32(-1)",      widen_ret_i32(-1),      (int64_t)(int32_t)-1);
    check("widen_ret_i32(INT32_MIN)", widen_ret_i32(INT32_MIN), (int64_t)INT32_MIN);

    check("widen_param_i32(-1000)", widen_param_i32(-1000), (int64_t)(int32_t)-1000);
    check("widen_param_i32(1000)",  widen_param_i32(1000),  (int64_t)(int32_t)1000);

    check("widen_local_i32(-1000)", widen_local_i32(-1000), (int64_t)(int32_t)-1000);
    check("widen_local_i32(7)",     widen_local_i32(7),     (int64_t)(int32_t)7);

    check("widen_array_i32(-1000)", widen_array_i32(-1000), (int64_t)(int32_t)-1000);
    check("widen_array_i32(42)",    widen_array_i32(42),    (int64_t)(int32_t)42);

    check("widen_double_cast_i32(-1000)", widen_double_cast_i32(-1000),
          (int64_t)(int32_t)-1000);
    check("widen_double_cast_i32(123)",   widen_double_cast_i32(123),
          (int64_t)(int32_t)123);

    /* Narrower signed sources. */
    check("widen_param_i16(-300)",  widen_param_i16(-300),  (int64_t)(int16_t)-300);
    check("widen_param_i16(300)",   widen_param_i16(300),   (int64_t)(int16_t)300);
    check("widen_param_i8(-5)",     widen_param_i8(-5),     (int64_t)(int8_t)-5);
    check("widen_param_i8(5)",      widen_param_i8(5),      (int64_t)(int8_t)5);

    /* UNSIGNED sources MUST zero-extend — high-bit-set must NOT bleed. */
    check("widen_param_u32(0xFFFFFC18)", widen_param_u32(0xFFFFFC18u),
          (int64_t)(uint64_t)0xFFFFFC18ull);
    check("widen_param_u32(1000)", widen_param_u32(1000u), (int64_t)1000);
    check("widen_param_u16(0xFFFF)", widen_param_u16(0xFFFFu),
          (int64_t)(uint64_t)0xFFFFull);

    /* The real bug shape: a widened negative must compare < 0. */
    check("widened_is_negative(-1000)", widened_is_negative(-1000), 1);
    check("widened_is_negative(1000)",  widened_is_negative(1000),  0);
    check("widened_is_negative(-1)",    widened_is_negative(-1),    1);

    if (fails) {
        fprintf(stderr, "[compiler_sext_widen] FAIL: %d case(s)\n", fails);
        return 1;
    }
    printf("[compiler_sext_widen] PASS\n");
    return 0;
}
EOF

CC="${CC:-cc}"
"$CC" -no-pie -O0 "$ASM" "$DRIVER" -o "$BIN"

echo "[$TAG] (3/3) Run sign/zero-extension assertions"
"$BIN"
