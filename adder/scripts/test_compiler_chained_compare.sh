#!/usr/bin/env bash
# scripts/test_compiler_chained_compare.sh — Python-style chained comparisons
#
# Background: `a OP1 b OP2 c` in Python means `(a OP1 b) and (b OP2 c)`, NOT
# the C-style `(a OP1 b) OP2 c` (which would compare a boolean 0/1 against c).
# The codegen now detects left-nested relational BinaryExprs and lowers them to
# the correct AND-of-pairs semantics, evaluating each middle operand only once
# and short-circuiting when any pair is false.
#
# This is a HOST-SIDE test: compile to x86_64 SysV asm, assemble, link against
# a tiny C driver, run, and assert each computed result.
#
# PASS criterion: all fixture functions return their expected values, the
# driver prints ALL PASS, exit 0.

set -uo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"
TMP="$(mktemp -d)"
trap "rm -rf $TMP" EXIT

FIX=tests/test_compiler_chained_compare.ad
ASM="$TMP/chained_compare.s"
OBJ="$TMP/chained_compare.o"
BIN="$TMP/chained_compare_test"

echo "[chained_compare] (1/4) Compile fixture to x86_64 asm"
if ! python3 -m compiler.adder asm --target=x86_64-adder-user \
        "$FIX" -o "$ASM" >"$TMP/asm.log" 2>&1; then
    echo "[chained_compare] FAIL: fixture did not compile to asm"
    cat "$TMP/asm.log"
    exit 1
fi

echo "[chained_compare] (2/4) Asm-shape sanity check"
# A chained comparison must NOT just be a pair of cmpq/setcc with no
# intervening short-circuit branch.  Verify that the chain labels appear.
if ! grep -q "chain_false" "$ASM"; then
    echo "[chained_compare] FAIL: 'chain_false' label not found — codegen may be using wrong lowering"
    exit 1
fi
echo "[chained_compare] OK: chain_false label present"

echo "[chained_compare] (3/4) Assemble + link with host C driver"
if ! gcc -c "$ASM" -o "$OBJ" 2>"$TMP/as.log"; then
    echo "[chained_compare] FAIL: emitted asm did not assemble"
    cat "$TMP/as.log"
    exit 1
fi

cat > "$TMP/driver.c" <<'EOF'
#include <stdio.h>
extern int test_lt_false(void);
extern int test_lt_true(void);
extern int test_range_true(void);
extern int test_range_false(void);
extern int test_3way_true(void);
extern int test_3way_false(void);

struct tc { const char *name; int got; int want; };

int main(void) {
    struct tc cases[] = {
        { "lt_false",    test_lt_false(),   0 },
        { "lt_true",     test_lt_true(),    1 },
        { "range_true",  test_range_true(), 1 },
        { "range_false", test_range_false(),0 },
        { "3way_true",   test_3way_true(),  1 },
        { "3way_false",  test_3way_false(), 0 },
    };
    int n = (int)(sizeof(cases) / sizeof(cases[0]));
    int ok = 1;
    for (int i = 0; i < n; i++) {
        int pass = (cases[i].got == cases[i].want);
        printf("[chained_compare]   %-12s got=%-4d want=%-4d %s\n",
               cases[i].name, cases[i].got, cases[i].want,
               pass ? "OK" : "FAIL");
        if (!pass) ok = 0;
    }
    printf("[chained_compare] %s\n", ok ? "ALL PASS" : "SOME FAILED");
    return ok ? 0 : 1;
}
EOF

if ! gcc "$TMP/driver.c" "$OBJ" -o "$BIN" 2>"$TMP/link.log"; then
    echo "[chained_compare] FAIL: link against C driver failed"
    cat "$TMP/link.log"
    exit 1
fi

echo "[chained_compare] (4/4) Run and assert computed results"
if ! "$BIN"; then
    echo "[chained_compare] FAIL: one or more chained-comparison results were wrong"
    exit 1
fi

echo "[chained_compare] PASS"
exit 0
