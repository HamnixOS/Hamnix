#!/usr/bin/env bash
# scripts/test_compiler_sizeof.sh — compile-time sizeof(T) builtin
#
# Background: `sizeof(T)` is a compile-time builtin that folds to an integer
# constant at codegen time — emitting `movq $N, %rax` with no runtime call
# and no heap allocation. Works for all scalar types, Ptr[T], Array[N, T],
# and struct types (using their ABI layout size).
#
# This is a HOST-SIDE test: compile to x86_64 SysV asm, assemble, link against
# a tiny C driver, run, and assert each computed result.
#
# PASS criterion: all fixture functions return their expected sizeof values, the
# driver prints ALL PASS, exit 0.

set -uo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"
TMP="$(mktemp -d)"
trap "rm -rf $TMP" EXIT

FIX=tests/test_compiler_sizeof.ad
ASM="$TMP/sizeof.s"
OBJ="$TMP/sizeof.o"
BIN="$TMP/sizeof_test"

echo "[sizeof] (1/4) Compile fixture to x86_64 asm"
if ! python3 -m compiler.adder asm --target=x86_64-adder-user \
        "$FIX" -o "$ASM" >"$TMP/asm.log" 2>&1; then
    echo "[sizeof] FAIL: fixture did not compile to asm"
    cat "$TMP/asm.log"
    exit 1
fi

echo "[sizeof] (2/4) Asm-shape sanity check"
# sizeof must be a pure immediate — no call instructions, no runtime symbol.
# Verify that no 'call' to a sizeof runtime helper appears.
if grep -q "call.*sizeof" "$ASM"; then
    echo "[sizeof] FAIL: 'call sizeof' found in asm — codegen is not folding to immediate"
    exit 1
fi
# Verify that at least one immediate constant was emitted.
if ! grep -qE "movq \\\$[0-9]" "$ASM"; then
    echo "[sizeof] FAIL: no movq \$N immediates found in asm"
    exit 1
fi
echo "[sizeof] OK: folds to immediates (no sizeof runtime call)"

echo "[sizeof] (3/4) Assemble + link with host C driver"
if ! gcc -c "$ASM" -o "$OBJ" 2>"$TMP/as.log"; then
    echo "[sizeof] FAIL: emitted asm did not assemble"
    cat "$TMP/as.log"
    exit 1
fi

cat > "$TMP/driver.c" <<'EOF'
#include <stdio.h>
extern int sizeof_int8(void);
extern int sizeof_int16(void);
extern int sizeof_int32(void);
extern int sizeof_int64(void);
extern int sizeof_uint8(void);
extern int sizeof_uint16(void);
extern int sizeof_uint32(void);
extern int sizeof_uint64(void);
extern int sizeof_ptr(void);
extern int sizeof_arr8(void);
extern int sizeof_arr4i(void);
extern int sizeof_two_ints(void);
extern int sizeof_times2(void);
extern int sizeof_in_expr(void);

struct tc { const char *name; int got; int want; };

int main(void) {
    struct tc cases[] = {
        { "int8",      sizeof_int8(),      1 },
        { "int16",     sizeof_int16(),     2 },
        { "int32",     sizeof_int32(),     4 },
        { "int64",     sizeof_int64(),     8 },
        { "uint8",     sizeof_uint8(),     1 },
        { "uint16",    sizeof_uint16(),    2 },
        { "uint32",    sizeof_uint32(),    4 },
        { "uint64",    sizeof_uint64(),    8 },
        { "ptr",       sizeof_ptr(),       8 },
        { "arr8",      sizeof_arr8(),      8 },
        { "arr4i",     sizeof_arr4i(),    16 },
        { "two_ints",  sizeof_two_ints(),  8 },
        { "times2",    sizeof_times2(),    8 },
        { "in_expr",   sizeof_in_expr(),   8 },
    };
    int n = (int)(sizeof(cases) / sizeof(cases[0]));
    int ok = 1;
    for (int i = 0; i < n; i++) {
        int pass = (cases[i].got == cases[i].want);
        printf("[sizeof]   %-12s got=%-4d want=%-4d %s\n",
               cases[i].name, cases[i].got, cases[i].want,
               pass ? "OK" : "FAIL");
        if (!pass) ok = 0;
    }
    printf("[sizeof] %s\n", ok ? "ALL PASS" : "SOME FAILED");
    return ok ? 0 : 1;
}
EOF

if ! gcc "$TMP/driver.c" "$OBJ" -o "$BIN" 2>"$TMP/link.log"; then
    echo "[sizeof] FAIL: link against C driver failed"
    cat "$TMP/link.log"
    exit 1
fi

echo "[sizeof] (4/4) Run and assert sizeof values"
if ! "$BIN"; then
    echo "[sizeof] FAIL: one or more sizeof results were wrong"
    exit 1
fi

echo "[sizeof] PASS"
exit 0
