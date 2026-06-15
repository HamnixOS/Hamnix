#!/usr/bin/env bash
# scripts/test_compiler_unreserved_idents.sh — regression proving that
# `bytes` and `field` parse as ordinary identifiers.
#
# Background: both were keywords in `compiler/lexer.py`'s lookup table
# (`"bytes": TokenType.BYTES`, `"field": TokenType.FIELD`), but no
# parser / codegen consumer ever matched the resulting tokens. They
# shipped as speculative reservations — `BYTES = auto()` literally
# carried the comment "Could add BYTES type later". Agents writing
# natural code kept hitting them as parameter names (`bytes` as a
# count) or loop vars (`field` in a /proc/PID/stat walk, quirks doc
# 2026-06-02). Un-reserved 2026-06-15 by dropping the keyword-table
# entries; the TokenType enum values are retained so downstream
# consumers that pattern-match on TokenType still compile.
#
# Strategy: compile a fixture that uses both names as parameters,
# loop vars, and locals, link against a host C driver that calls each
# function with known values, assert the result.
#
# PASS criterion: "[compiler_unreserved_idents] PASS" on stdout.

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

TAG="compiler_unreserved_idents"
FIXTURE="tests/test_compiler_unreserved_idents.ad"
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

echo "[$TAG] (2/3) Assemble + link"
cat > "$DRIVER" <<'EOF'
#include <stdio.h>
#include <stdint.h>

extern int64_t take_field(int64_t field);
extern int64_t sum_fields(int64_t n);
extern int64_t double_bytes(int64_t bytes);
extern int64_t count_up(int64_t limit);
extern int64_t stat_walk(int64_t n, int64_t bytes);

static int fails = 0;
#define CHECK(call, want) do {                                    \
    int64_t _g = (call); int64_t _w = (int64_t)(want);            \
    if (_g != _w) {                                               \
        fprintf(stderr, "[" "compiler_unreserved_idents" "] "     \
                "FAIL: %s = %lld, expected %lld\n", #call,        \
                (long long)_g, (long long)_w); fails++;           \
    }                                                             \
} while (0)

int main(void) {
    /* `field` as a parameter name. */
    CHECK(take_field(0),   1);
    CHECK(take_field(41), 42);

    /* `field` as a loop variable: sum 0..n-1. */
    CHECK(sum_fields(0),   0);
    CHECK(sum_fields(1),   0);
    CHECK(sum_fields(5),  10);  /* 0+1+2+3+4 */
    CHECK(sum_fields(10), 45);

    /* `bytes` as a parameter name. */
    CHECK(double_bytes(0),   0);
    CHECK(double_bytes(21), 42);

    /* `bytes` as a local. */
    CHECK(count_up(0),   0);
    CHECK(count_up(7),   7);

    /* Both at once. */
    CHECK(stat_walk(0,  100), 100);
    CHECK(stat_walk(5,  100), 110);  /* 100 + 0+1+2+3+4 */
    CHECK(stat_walk(10,  0),  45);

    if (fails) {
        fprintf(stderr, "[compiler_unreserved_idents] FAIL: %d case(s)\n",
                fails);
        return 1;
    }
    printf("[compiler_unreserved_idents] PASS\n");
    return 0;
}
EOF

CC="${CC:-cc}"
"$CC" -no-pie -O0 "$ASM" "$DRIVER" -o "$BIN"

echo "[$TAG] (3/3) Run identifier-name assertions"
"$BIN"
