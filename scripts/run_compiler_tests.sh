#!/usr/bin/env bash
# scripts/run_compiler_tests.sh — master runner for the host-side Adder
# compiler regression suite (scripts/test_compiler_*.sh).
#
# These are pure compiler/codegen regressions: each compiles a fixture in
# tests/test_compiler_*.ad through the real backend, links it against a C
# driver, and asserts runtime behavior — no QEMU boot required. They are
# fast and deterministic, suitable for every CI run.
#
# Exit non-zero if ANY sub-test fails.

set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

rc=0
for t in scripts/test_compiler_*.sh; do
    echo "==> $t"
    if bash "$t"; then
        echo "    PASS: $t"
    else
        echo "    FAIL: $t"
        rc=1
    fi
done

if [ "$rc" -eq 0 ]; then
    echo "[run_compiler_tests] ALL PASS"
else
    echo "[run_compiler_tests] FAILURES"
fi
exit "$rc"
