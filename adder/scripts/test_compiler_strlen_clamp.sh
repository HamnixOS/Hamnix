#!/usr/bin/env bash
# scripts/test_compiler_strlen_clamp.sh — inline strlen + clamp builtins
#
# Background: strlen(s) and clamp(x, lo, hi) are lowered inline by the
# x86_64 codegen — no call instruction, no heap. They are only intercepted
# when the name is NOT shadowed by a user-defined function or local variable.
#
#   strlen(s: Ptr[uint8]) -> uint64
#     Emits `repne scasb` — scans for the NUL byte and computes the count.
#
#   clamp(x, lo, hi) — value type
#     Emits two cmpq + cmovl/cmovg pairs: first clamps x up to lo if needed,
#     then clamps the result down to hi if needed.
#
# This is a HOST-SIDE test: compile to x86_64 SysV asm, assemble, link
# against a tiny C driver, run, and assert each computed result. Runs in
# well under a second.
#
# PASS criterion: all fixture functions return their expected values, the
# driver prints ALL PASS, and exits 0.

set -uo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"
TMP="$(mktemp -d)"
trap "rm -rf $TMP" EXIT

FIX=tests/test_compiler_strlen_clamp.ad
ASM="$TMP/strlen_clamp.s"
OBJ="$TMP/strlen_clamp.o"
BIN="$TMP/strlen_clamp_test"

echo "[strlen_clamp] (1/4) Compile fixture to x86_64 asm"
if ! python3 -m compiler.adder asm --target=x86_64-adder-user \
        "$FIX" -o "$ASM" >"$TMP/asm.log" 2>&1; then
    echo "[strlen_clamp] FAIL: fixture did not compile to asm"
    cat "$TMP/asm.log"
    exit 1
fi

echo "[strlen_clamp] (2/4) Asm-shape sanity check"
# strlen must be pure inline (repne scasb) — no call to strlen/strlen_u8.
if grep -qE "call\s+strlen" "$ASM"; then
    echo "[strlen_clamp] FAIL: call to strlen found in asm — codegen is not inlining"
    exit 1
fi
# Verify repne scasb is present (the strlen inline expansion uses it)
if ! grep -q "repne scasb" "$ASM"; then
    echo "[strlen_clamp] FAIL: no repne scasb found — strlen inline missing"
    exit 1
fi
echo "[strlen_clamp] OK: repne scasb present, no runtime strlen call"

# clamp must be pure inline (cmpq + cmovl + cmovg) — no call to clamp.
if grep -qE "call\s+clamp" "$ASM"; then
    echo "[strlen_clamp] FAIL: call to clamp found in asm — codegen is not inlining"
    exit 1
fi
# Verify both cmovl and cmovg are present (the clamp inline uses both)
if ! grep -q "cmovl" "$ASM"; then
    echo "[strlen_clamp] FAIL: no cmovl found — clamp lo-bound missing"
    exit 1
fi
if ! grep -q "cmovg" "$ASM"; then
    echo "[strlen_clamp] FAIL: no cmovg found — clamp hi-bound missing"
    exit 1
fi
echo "[strlen_clamp] OK: cmovl + cmovg present, no runtime clamp call"

echo "[strlen_clamp] (3/4) Assemble + link with host C driver"
if ! gcc -c "$ASM" -o "$OBJ" 2>"$TMP/as.log"; then
    echo "[strlen_clamp] FAIL: emitted asm did not assemble"
    cat "$TMP/as.log"
    exit 1
fi

cat > "$TMP/driver.c" <<'EOF'
#include <stdio.h>
#include <stdint.h>

/* Stack-protector stubs — the Adder fixture has Array globals that trigger
   the canary instrumentation; without these the linker can't resolve
   __stack_chk_guard / __stack_chk_fail. */
uintptr_t __stack_chk_guard = 0xdeadbeefcafe0000UL;
void __stack_chk_fail(void) { fprintf(stderr, "stack smash!\n"); __builtin_trap(); }

extern int test_strlen_empty(void);
extern int test_strlen_hello(void);
extern int test_strlen_one(void);
extern int test_strlen_literal(void);
extern int test_strlen_long(void);
extern int test_strlen_twice(void);
extern int test_clamp_below(void);
extern int test_clamp_above(void);
extern int test_clamp_mid(void);
extern int test_clamp_at_lo(void);
extern int test_clamp_at_hi(void);
extern int test_clamp_neg(void);
extern int test_clamp_i64(void);

struct tc { const char *name; int got; int want; };

int main(void) {
    struct tc cases[] = {
        { "strlen_empty",   test_strlen_empty(),   0    },
        { "strlen_hello",   test_strlen_hello(),   5    },
        { "strlen_one",     test_strlen_one(),     1    },
        { "strlen_literal", test_strlen_literal(), 5    },
        { "strlen_long",    test_strlen_long(),    13   },
        { "strlen_twice",   test_strlen_twice(),   6    },
        { "clamp_below",    test_clamp_below(),    10   },
        { "clamp_above",    test_clamp_above(),    20   },
        { "clamp_mid",      test_clamp_mid(),      15   },
        { "clamp_at_lo",    test_clamp_at_lo(),    10   },
        { "clamp_at_hi",    test_clamp_at_hi(),    20   },
        { "clamp_neg",      test_clamp_neg(),      -5   },
        { "clamp_i64",      test_clamp_i64(),      1000 },
    };
    int n = (int)(sizeof(cases) / sizeof(cases[0]));
    int ok = 1;
    for (int i = 0; i < n; i++) {
        int pass = (cases[i].got == cases[i].want);
        printf("[strlen_clamp]   %-16s got=%-5d want=%-5d %s\n",
               cases[i].name, cases[i].got, cases[i].want,
               pass ? "OK" : "FAIL");
        if (!pass) ok = 0;
    }
    printf("[strlen_clamp] %s\n", ok ? "ALL PASS" : "SOME FAILED");
    return ok ? 0 : 1;
}
EOF

if ! gcc "$TMP/driver.c" "$OBJ" -o "$BIN" 2>"$TMP/link.log"; then
    echo "[strlen_clamp] FAIL: link against C driver failed"
    cat "$TMP/link.log"
    exit 1
fi

echo "[strlen_clamp] (4/4) Run and assert computed results"
if ! "$BIN"; then
    echo "[strlen_clamp] FAIL: one or more strlen/clamp results were wrong"
    exit 1
fi

echo "[strlen_clamp] PASS"
exit 0
