#!/usr/bin/env bash
# scripts/test_adder_pin.sh — functional check that the in-tree Adder
# compiler is wired up and compiles.
#
# History: Adder used to live in its own repo (HamnixOS/adder) consumed
# as a git submodule, and this script enforced the submodule pin against
# upstream ("adder moves with hamnix first-class; drift unacceptable",
# user 2026-05-26). As of the repo consolidation (2026-05-30) Adder is
# INLINED under adder/ as regular tracked files, so drift is impossible
# by construction — there is no pin to verify. What remains worth
# guarding is that the compiler still compiles a trivial program through
# the canonical `python3 -m compiler.adder` import path (which resolves
# via the `compiler -> adder/compiler` symlink the build scripts use).
#
# Runs in well under 5 seconds. Has zero kernel dependencies.
#
# Usage:
#   bash scripts/test_adder_pin.sh
#
# Exits 0 on PASS, non-zero on failure.

set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

fail=0

# --- 1. The compiler tree is present in-tree (not a bare gitlink). ---
if [ ! -e adder/compiler/adder.py ]; then
    echo "[adder_pin] FAIL: adder/compiler/adder.py missing — the inlined compiler tree is gone"
    exit 1
fi
if [ ! -e compiler ]; then
    echo "[adder_pin] FAIL: 'compiler' symlink missing (should point at adder/compiler)"
    fail=1
fi

# --- 2. The compiler is functional via the canonical import path. ---
TMP="$(mktemp -d)"
trap "rm -rf $TMP" EXIT
cat > "$TMP/smoke.ad" <<'ADEOF'
def add(a: int32, b: int32) -> int32:
    return a + b

def main() -> int32:
    return add(40, 2)
ADEOF

if python3 -m compiler.adder asm --target=x86_64-adder-user \
        "$TMP/smoke.ad" -o "$TMP/smoke.s" >"$TMP/build.log" 2>&1; then
    if grep -q '^add:' "$TMP/smoke.s" && grep -q '^main:' "$TMP/smoke.s"; then
        echo "[adder_pin] python3 -m compiler.adder works through the symlink — OK"
    else
        echo "[adder_pin] FAIL: smoke compile produced asm without expected labels"
        echo "--- smoke.s (head) ---"
        head -20 "$TMP/smoke.s"
        fail=1
    fi
else
    echo "[adder_pin] FAIL: python3 -m compiler.adder failed on a trivial program"
    cat "$TMP/build.log"
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[adder_pin] FAIL"
    exit 1
fi

echo "[adder_pin] PASS"
exit 0
