#!/usr/bin/env bash
# scripts/test_compiler_minmax_abs.sh — inline min/max/abs builtins
#
# Background: min(a, b), max(a, b), and abs(x) are lowered inline to
# cmpq + cmov — zero hidden control flow, zero heap allocation, no call
# instruction. The intrinsics are only intercepted when the name is NOT
# shadowed by a user-defined function or local variable.
#
# This is a HOST-SIDE test: compile to x86_64 SysV asm, assemble, link
# against a tiny C driver, run, and assert each computed result.
#
# PASS criterion: all fixture functions return their expected values, the
# driver prints ALL PASS, exit 0.

set -uo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"
TMP="$(mktemp -d)"
trap "rm -rf $TMP" EXIT

FIX=tests/test_compiler_minmax_abs.ad
ASM="$TMP/minmax_abs.s"
OBJ="$TMP/minmax_abs.o"
BIN="$TMP/minmax_abs_test"

echo "[minmax_abs] (1/4) Compile fixture to x86_64 asm"
if ! python3 -m compiler.adder asm --target=x86_64-adder-user \
        "$FIX" -o "$ASM" >"$TMP/asm.log" 2>&1; then
    echo "[minmax_abs] FAIL: fixture did not compile to asm"
    cat "$TMP/asm.log"
    exit 1
fi

echo "[minmax_abs] (2/4) Asm-shape sanity check"
# min/max/abs must be pure inline (cmp + cmov) — no call to a runtime helper.
if grep -qE "call\s+(min|max|abs)" "$ASM"; then
    echo "[minmax_abs] FAIL: call to min/max/abs found in asm — codegen is not inlining"
    exit 1
fi
# Verify cmov instructions are present (the inline expansion uses them)
if ! grep -qE "cmov" "$ASM"; then
    echo "[minmax_abs] FAIL: no cmov instructions found — inline expansion missing"
    exit 1
fi
echo "[minmax_abs] OK: cmov present, no runtime min/max/abs call"

echo "[minmax_abs] (3/4) Assemble + link with host C driver"
if ! gcc -c "$ASM" -o "$OBJ" 2>"$TMP/as.log"; then
    echo "[minmax_abs] FAIL: emitted asm did not assemble"
    cat "$TMP/as.log"
    exit 1
fi

cat > "$TMP/driver.c" <<'EOF'
#include <stdio.h>
extern int test_min_a_less(void);
extern int test_min_b_less(void);
extern int test_min_equal(void);
extern int test_max_a_greater(void);
extern int test_max_b_greater(void);
extern int test_max_equal(void);
extern int test_abs_pos(void);
extern int test_abs_neg(void);
extern int test_abs_zero(void);
extern int test_min_i64(void);
extern int test_max_i64(void);

struct tc { const char *name; int got; int want; };

int main(void) {
    struct tc cases[] = {
        { "min_a_less",    test_min_a_less(),    3 },
        { "min_b_less",    test_min_b_less(),    2 },
        { "min_equal",     test_min_equal(),     5 },
        { "max_a_greater", test_max_a_greater(), 9 },
        { "max_b_greater", test_max_b_greater(), 8 },
        { "max_equal",     test_max_equal(),     6 },
        { "abs_pos",       test_abs_pos(),       5 },
        { "abs_neg",       test_abs_neg(),       5 },
        { "abs_zero",      test_abs_zero(),      0 },
        { "min_i64",       test_min_i64(),     100 },
        { "max_i64",       test_max_i64(),     200 },
    };
    int n = (int)(sizeof(cases) / sizeof(cases[0]));
    int ok = 1;
    for (int i = 0; i < n; i++) {
        int pass = (cases[i].got == cases[i].want);
        printf("[minmax_abs]   %-16s got=%-4d want=%-4d %s\n",
               cases[i].name, cases[i].got, cases[i].want,
               pass ? "OK" : "FAIL");
        if (!pass) ok = 0;
    }
    printf("[minmax_abs] %s\n", ok ? "ALL PASS" : "SOME FAILED");
    return ok ? 0 : 1;
}
EOF

if ! gcc "$TMP/driver.c" "$OBJ" -o "$BIN" 2>"$TMP/link.log"; then
    echo "[minmax_abs] FAIL: link against C driver failed"
    cat "$TMP/link.log"
    exit 1
fi

echo "[minmax_abs] (4/4) Run and assert computed results"
if ! "$BIN"; then
    echo "[minmax_abs] FAIL: one or more min/max/abs results were wrong"
    exit 1
fi

echo "[minmax_abs] PASS"
exit 0
