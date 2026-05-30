#!/usr/bin/env bash
# scripts/test_compiler_string_concat.sh — adjacent string literal concatenation
#
# Background: "foo" "bar" should lex/parse as the single literal "foobar" (the
# same rule as C and Python). This was explicitly listed in LANGUAGE.md as
# UNSUPPORTED before this commit. The fixture functions return integers derived
# from string lengths so the C driver can assert them without a printf helper.
#
# PASS criterion: all four functions return their expected lengths and the
# driver prints ALL PASS, exit 0.

set -uo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"
TMP="$(mktemp -d)"
trap "rm -rf $TMP" EXIT

FIX=tests/test_compiler_string_concat.ad
ASM="$TMP/string_concat.s"
OBJ="$TMP/string_concat.o"
BIN="$TMP/string_concat_test"

echo "[string_concat] (1/4) Compile fixture to x86_64 asm"
if ! python3 -m compiler.adder asm --target=x86_64-adder-user \
        "$FIX" -o "$ASM" >"$TMP/asm.log" 2>&1; then
    echo "[string_concat] FAIL: fixture did not compile to asm"
    cat "$TMP/asm.log"
    exit 1
fi

echo "[string_concat] (2/4) Verify concatenated strings appear in .rodata"
# "Hello, World!" should appear as the concatenation of "Hello, " and "World!";
# the assembler directive should NOT contain two separate labels for the pieces.
if ! grep -qF 'Hello, World!' "$ASM"; then
    echo "[string_concat] FAIL: 'Hello, World!' not found in emitted asm"
    echo "  (adjacent string concatenation may not be working)"
    exit 1
fi
if ! grep -qF 'foobarbaz' "$ASM"; then
    echo "[string_concat] FAIL: 'foobarbaz' not found in emitted asm"
    exit 1
fi
echo "[string_concat] OK: concatenated literals present in asm"

echo "[string_concat] (3/4) Assemble + link with host C driver"
if ! gcc -c "$ASM" -o "$OBJ" 2>"$TMP/as.log"; then
    echo "[string_concat] FAIL: emitted asm did not assemble"
    cat "$TMP/as.log"
    exit 1
fi

cat > "$TMP/driver.c" <<'EOF'
#include <stdio.h>
extern int concat_basic(void);
extern int concat_triple(void);
extern int concat_escapes(void);
extern int concat_in_arg(void);

struct tc { const char *name; int got; int want; };

int main(void) {
    struct tc cases[] = {
        { "concat_basic",   concat_basic(),   13 },
        { "concat_triple",  concat_triple(),   9 },
        { "concat_escapes", concat_escapes(),  2 },
        { "concat_in_arg",  concat_in_arg(),   4 },
    };
    int n = (int)(sizeof(cases) / sizeof(cases[0]));
    int ok = 1;
    for (int i = 0; i < n; i++) {
        int pass = (cases[i].got == cases[i].want);
        printf("[string_concat]   %-16s got=%-4d want=%-4d %s\n",
               cases[i].name, cases[i].got, cases[i].want,
               pass ? "OK" : "FAIL");
        if (!pass) ok = 0;
    }
    printf("[string_concat] %s\n", ok ? "ALL PASS" : "SOME FAILED");
    return ok ? 0 : 1;
}
EOF

if ! gcc "$TMP/driver.c" "$OBJ" -o "$BIN" 2>"$TMP/link.log"; then
    echo "[string_concat] FAIL: link against C driver failed"
    cat "$TMP/link.log"
    exit 1
fi

echo "[string_concat] (4/4) Run and assert computed results"
if ! "$BIN"; then
    echo "[string_concat] FAIL: one or more string-concat results were wrong"
    exit 1
fi

echo "[string_concat] PASS"
exit 0
