#!/usr/bin/env bash
# scripts/run_compiler_tests.sh — canonical "did the compiler regress?" check.
#
# Runs every per-quirk regression fixture serially and reports a one-line
# PASS / FAIL summary per test, then a final aggregate. Exits 0 iff every
# test passes (or xfails as expected). Used by future fix-this-quirk
# agents as their gating check before committing.
#
# Convention: one fixture per known quirk, named
# `tests/test_compiler_<short_name>.ad` driven by
# `scripts/test_compiler_<short_name>.sh`, plus the lexer fixtures
# (`scripts/test_lex_*.sh`) and the host-side `compiler/lexer_test.py`.
# See CONTRIBUTING.md "Compiler regression suite".
#
# Each individual test owns its own per-worktree build lock (see
# scripts/_build_lock.sh) so running this serially is safe; running
# two copies of this script in the SAME worktree at once would race
# on the lock and serialise anyway.
#
# Usage:
#   bash scripts/run_compiler_tests.sh
#
# Per-test output is captured to /tmp/run_compiler_tests.<name>.log so
# the summary stays readable. Set HAMNIX_COMPILER_TESTS_VERBOSE=1 to
# stream each test's output live instead.

set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

VERBOSE="${HAMNIX_COMPILER_TESTS_VERBOSE:-0}"

# Order: cheapest first. lexer_test is pure-Python (<1s). The
# QEMU-boot fixtures take ~30-90s each.
TESTS=(
    "lexer_test:python3 compiler/lexer_test.py"
    "lex_digit_idents:bash scripts/test_lex_digit_idents.sh"
    "ptr_local:bash scripts/test_compiler_ptr_local.sh"
    "addr_of_nested:bash scripts/test_compiler_addr_of_nested.sh"
    "cast_arr_u32:bash scripts/test_compiler_cast_arr_u32.sh"
    "nested_frame_array:bash scripts/test_compiler_nested_frame_array.sh"
    "nested_class_fields:bash scripts/test_compiler_nested_class_fields.sh"
    "string_global:bash scripts/test_compiler_string_global.sh"
    "fnptr:bash scripts/test_compiler_fnptr.sh"
    "stack_canary:bash scripts/test_compiler_stack_canary.sh"
    "unsigned_divshift:bash scripts/test_compiler_unsigned_divshift.sh"
    "module_private:bash scripts/test_compiler_module_private.sh"
    "class_inheritance:bash scripts/test_compiler_class_inheritance.sh"
    "unsupported_rejected:bash scripts/test_compiler_unsupported_rejected.sh"
)

results=()
overall=0

echo "=== Hamnix compiler regression suite ==="
echo "worktree: $PROJ_ROOT"
echo "tests:    ${#TESTS[@]}"
echo "---"

for entry in "${TESTS[@]}"; do
    name="${entry%%:*}"
    cmd="${entry#*:}"
    log="/tmp/run_compiler_tests.$name.log"

    printf "[%-22s] running... " "$name"

    if [ "$VERBOSE" = "1" ]; then
        echo ""
        if eval "$cmd"; then
            rc=0
        else
            rc=$?
        fi
        printf "[%-22s] " "$name"
    else
        if eval "$cmd" >"$log" 2>&1; then
            rc=0
        else
            rc=$?
        fi
    fi

    if [ "$rc" -eq 0 ]; then
        echo "PASS"
        results+=("PASS  $name")
    else
        echo "FAIL (rc=$rc, log: $log)"
        results+=("FAIL  $name  (rc=$rc, log: $log)")
        overall=1
    fi
done

echo "---"
echo "=== summary ==="
for line in "${results[@]}"; do
    echo "  $line"
done

if [ "$overall" -eq 0 ]; then
    echo "=== ALL GREEN ==="
    exit 0
fi

echo "=== REGRESSION ==="
echo "Re-run with HAMNIX_COMPILER_TESTS_VERBOSE=1 to see live output,"
echo "or inspect the per-test logs listed above."
exit 1
