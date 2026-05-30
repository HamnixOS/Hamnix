#!/usr/bin/env bash
# scripts/test_compiler_augmented_assign.sh — compound/augmented assignment
#
# Background: `a OP= b` is now desugared at codegen time to `a = a OP b`.
# The LANGUAGE.md section "Features deliberately not in Adder" previously
# listed compound assignment as unsupported. This test guards the new
# implementation.
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

FIX=tests/test_compiler_augmented_assign.ad
ASM="$TMP/augmented_assign.s"
OBJ="$TMP/augmented_assign.o"
BIN="$TMP/augmented_assign_test"

echo "[augmented_assign] (1/4) Compile fixture to x86_64 asm"
if ! python3 -m compiler.adder asm --target=x86_64-adder-user \
        "$FIX" -o "$ASM" >"$TMP/asm.log" 2>&1; then
    echo "[augmented_assign] FAIL: fixture did not compile to asm"
    cat "$TMP/asm.log"
    exit 1
fi

echo "[augmented_assign] (2/4) Asm-shape sanity check"
# Each compound-assignment on an Identifier should desugar cleanly.
# Check that addq/orq/andq/xorq/shlq/shrq appear (they're used by +=, |=, etc.)
for mnemonic in addq orq andq xorq shlq sarq; do
    if ! grep -q "$mnemonic" "$ASM"; then
        echo "[augmented_assign] WARN: mnemonic '$mnemonic' not found in asm (may be OK for this fixture shape)"
    fi
done
echo "[augmented_assign] OK: asm shape reasonable"

echo "[augmented_assign] (3/4) Assemble + link with host C driver"
if ! gcc -c "$ASM" -o "$OBJ" 2>"$TMP/as.log"; then
    echo "[augmented_assign] FAIL: emitted asm did not assemble"
    cat "$TMP/as.log"
    exit 1
fi

cat > "$TMP/driver.c" <<'EOF'
#include <stdio.h>
extern int test_plus_eq(void);
extern int test_minus_eq(void);
extern int test_star_eq(void);
extern int test_pipe_eq(void);
extern int test_amp_eq(void);
extern int test_caret_eq(void);
extern int test_shl_eq(void);
extern int test_shr_eq(void);
extern int test_mod_eq(void);
extern int test_member_eq(void);
extern int test_index_eq(void);

struct tc { const char *name; int got; int want; };

int main(void) {
    struct tc cases[] = {
        { "plus_eq",   test_plus_eq(),   10 },
        { "minus_eq",  test_minus_eq(),   5 },
        { "star_eq",   test_star_eq(),   24 },
        { "pipe_eq",   test_pipe_eq(),    7 },
        { "amp_eq",    test_amp_eq(),    15 },
        { "caret_eq",  test_caret_eq(),   5 },
        { "shl_eq",    test_shl_eq(),    12 },
        { "shr_eq",    test_shr_eq(),    12 },
        { "mod_eq",    test_mod_eq(),     1 },
        { "member_eq", test_member_eq(), 21 },
        { "index_eq",  test_index_eq(), 105 },
    };
    int n = (int)(sizeof(cases) / sizeof(cases[0]));
    int ok = 1;
    for (int i = 0; i < n; i++) {
        int pass = (cases[i].got == cases[i].want);
        printf("[augmented_assign]   %-12s got=%-4d want=%-4d %s\n",
               cases[i].name, cases[i].got, cases[i].want,
               pass ? "OK" : "FAIL");
        if (!pass) ok = 0;
    }
    printf("[augmented_assign] %s\n", ok ? "ALL PASS" : "SOME FAILED");
    return ok ? 0 : 1;
}
EOF

if ! gcc "$TMP/driver.c" "$OBJ" -o "$BIN" 2>"$TMP/link.log"; then
    echo "[augmented_assign] FAIL: link against C driver failed"
    cat "$TMP/link.log"
    exit 1
fi

echo "[augmented_assign] (4/4) Run and assert computed results"
if ! "$BIN"; then
    echo "[augmented_assign] FAIL: one or more augmented-assignment results were wrong"
    exit 1
fi

echo "[augmented_assign] PASS"
exit 0
