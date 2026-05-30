#!/usr/bin/env bash
# scripts/test_compiler_for_loop.sh — compiler regression for `for ... in`
# loops (range() counters + fixed-size Array iteration).
#
# Background: the AST always had a ForStmt node and the parser built it,
# but the x86_64 codegen rejected ForStmt outright ("x86: statement
# ForStmt not yet supported"). As a result every loop in Hamnix was a
# hand-rolled `while` with an explicit counter. This test guards the
# new codegen lowering so it can't silently regress.
#
# This is a HOST-SIDE test: no QEMU boot. The fixture functions are pure
# integer computations with no syscalls, so we compile the fixture to
# x86_64 SysV asm with `compiler.adder asm`, assemble it, link it
# against a tiny C driver, RUN it on the host, and assert each
# computed result. Runs in well under a second. This both proves the
# emitted code EXECUTES correctly (not merely that it assembles) and
# does an asm-shape sanity check on the loop scaffolding.
#
# PASS criterion: every fixture function returns its known answer
# (45 / 18 / 5 / 15 / 105 / 10 / 25 / 9), the driver prints ALL PASS,
# and exits 0.

set -uo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"
TMP="$(mktemp -d)"
trap "rm -rf $TMP" EXIT

FIX=tests/test_compiler_for_loop.ad
ASM="$TMP/for_loop.s"
OBJ="$TMP/for_loop.o"
OBJ2="$TMP/for_loop_renamed.o"
BIN="$TMP/for_loop_test"

echo "[for_loop] (1/4) Compile fixture to x86_64 asm"
if ! python3 -m compiler.adder asm --target=x86_64-adder-user \
        "$FIX" -o "$ASM" >"$TMP/asm.log" 2>&1; then
    echo "[for_loop] FAIL: fixture did not compile to asm"
    cat "$TMP/asm.log"
    exit 1
fi

echo "[for_loop] (2/4) Asm-shape sanity check on the loop scaffolding"
# range() counter loops emit `.for_<fn>_N` / `.endfor_<fn>_N` labels;
# array iteration emits `.forarr_<fn>_N` / `.endforarr_<fn>_N`. If the
# lowering ever degrades back to "not supported" these vanish.
if ! grep -qE '^\.for_[A-Za-z0-9_]+_[0-9]+:' "$ASM"; then
    echo "[for_loop] FAIL: no range-loop label (.for_...) in emitted asm"
    exit 1
fi
if ! grep -qE '^\.forarr_[A-Za-z0-9_]+_[0-9]+:' "$ASM"; then
    echo "[for_loop] FAIL: no array-loop label (.forarr_...) in emitted asm"
    exit 1
fi
echo "[for_loop] OK: range + array loop scaffolding present"

echo "[for_loop] (3/4) Assemble + link with host C driver"
if ! gcc -c "$ASM" -o "$OBJ" 2>"$TMP/as.log"; then
    echo "[for_loop] FAIL: emitted asm did not assemble"
    cat "$TMP/as.log"
    exit 1
fi
# The fixture has no `main`, so no symbol clash — but link defensively.
cp "$OBJ" "$OBJ2"

cat > "$TMP/driver.c" <<'EOF'
#include <stdio.h>
extern int sum_to_ten(void);
extern int sum_range_3_7(void);
extern int step_count(void);
extern int descending_sum(void);
extern int sum_array(void);
extern int with_break(void);
extern int with_continue(void);
extern int nested(void);

struct tc { const char *name; int got; int want; };

int main(void) {
    struct tc cases[] = {
        { "sum_to_ten",     sum_to_ten(),     45  },
        { "sum_range_3_7",  sum_range_3_7(),  18  },
        { "step_count",     step_count(),     5   },
        { "descending_sum", descending_sum(), 15  },
        { "sum_array",      sum_array(),      105 },
        { "with_break",     with_break(),     10  },
        { "with_continue",  with_continue(),  25  },
        { "nested",         nested(),         9   },
    };
    int n = (int)(sizeof(cases) / sizeof(cases[0]));
    int ok = 1;
    for (int i = 0; i < n; i++) {
        int pass = (cases[i].got == cases[i].want);
        printf("[for_loop]   %-16s got=%-4d want=%-4d %s\n",
               cases[i].name, cases[i].got, cases[i].want,
               pass ? "OK" : "FAIL");
        if (!pass) ok = 0;
    }
    printf("[for_loop] %s\n", ok ? "ALL PASS" : "SOME FAILED");
    return ok ? 0 : 1;
}
EOF

if ! gcc "$TMP/driver.c" "$OBJ2" -o "$BIN" 2>"$TMP/link.log"; then
    echo "[for_loop] FAIL: link against C driver failed"
    cat "$TMP/link.log"
    exit 1
fi

echo "[for_loop] (4/4) Run and assert computed results"
if ! "$BIN"; then
    echo "[for_loop] FAIL: one or more for-loop results were wrong"
    exit 1
fi

echo "[for_loop] PASS"
exit 0
