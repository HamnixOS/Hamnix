#!/usr/bin/env bash
# scripts/test_adder_pin.sh — drift-check that the Adder submodule pin is
# REAL and the language is wired up correctly.
#
# Per user direction (2026-05-26): "adder moves with hamnix first-class;
# drift unacceptable." The Adder compiler lives in its own repo,
# HamnixOS/adder, and Hamnix consumes it as a git submodule pinned to a
# specific commit. This script enforces that the pin is:
#
#   1. ACTUALLY checked out — the submodule must be initialized (not a
#      bare gitlink waiting for `git submodule update --init`).
#   2. A REAL HamnixOS/adder commit — the pin must exist in the upstream
#      repo's history, not a local typo, a fork, or a force-rewritten
#      tree. In CI this fetches the upstream main and runs
#      `git merge-base --is-ancestor <pin> origin/main`. Offline, the
#      check falls back to "the commit exists in the submodule's reflog
#      / object DB" which is weaker but still catches typos.
#   3. FUNCTIONAL — the pinned compiler actually compiles a known
#      snippet through the canonical `python3 -m compiler.adder` import
#      path (which Hamnix's build scripts use). This catches a pin to a
#      commit where the Python package layout broke.
#
# Runs in well under 5 seconds. Has zero kernel dependencies.
#
# Usage:
#   bash scripts/test_adder_pin.sh
#
# Exits 0 on PASS, non-zero on any drift.

set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

fail=0

# --- 1. Submodule is initialized + pinned to a specific commit. ---
if [ ! -f .gitmodules ]; then
    echo "[adder_pin] FAIL: .gitmodules missing — submodule not declared"
    exit 1
fi
if ! grep -q '\[submodule "adder"\]' .gitmodules; then
    echo "[adder_pin] FAIL: .gitmodules has no [submodule \"adder\"] entry"
    exit 1
fi

status_line="$(git submodule status adder 2>/dev/null || true)"
if [ -z "$status_line" ]; then
    echo "[adder_pin] FAIL: 'git submodule status adder' returned nothing"
    exit 1
fi

# First column is a status char (' ' init, '-' not init, '+' modified,
# 'U' merge conflict). Strip it and grab the SHA.
first_char="${status_line:0:1}"
case "$first_char" in
    "-")
        echo "[adder_pin] FAIL: submodule not initialized — run: git submodule update --init adder"
        exit 1
        ;;
    "+")
        echo "[adder_pin] FAIL: submodule HEAD does not match the pin (uncommitted bump or detached drift):"
        echo "    $status_line"
        exit 1
        ;;
    "U")
        echo "[adder_pin] FAIL: submodule has merge conflicts:"
        echo "    $status_line"
        exit 1
        ;;
esac

pin_sha="$(echo "$status_line" | awk '{print $1}' | sed 's/^[+-]//')"
if [ -z "$pin_sha" ] || [ "${#pin_sha}" -lt 40 ]; then
    echo "[adder_pin] FAIL: could not extract a full SHA from: $status_line"
    exit 1
fi
echo "[adder_pin] submodule pin: $pin_sha"

# --- 2. The pin is a real HamnixOS/adder commit. ---
url="$(git config -f .gitmodules submodule.adder.url || true)"
if [ "$url" != "https://github.com/HamnixOS/adder.git" ] && \
   [ "$url" != "https://github.com/HamnixOS/adder" ] && \
   [ "$url" != "git@github.com:HamnixOS/adder.git" ]; then
    echo "[adder_pin] FAIL: submodule URL is not HamnixOS/adder: $url"
    fail=1
fi

# Try a real upstream fetch + ancestry check. If offline, fall back to
# "commit object exists in the submodule's local object DB".
if (cd adder && git fetch --quiet origin main 2>/dev/null); then
    if (cd adder && git merge-base --is-ancestor "$pin_sha" origin/main 2>/dev/null); then
        echo "[adder_pin] pin is an ancestor of HamnixOS/adder origin/main — OK"
    else
        echo "[adder_pin] FAIL: pin $pin_sha is NOT an ancestor of HamnixOS/adder origin/main"
        echo "    (pin must be on the upstream main branch — drift detected)"
        fail=1
    fi
else
    # Offline fallback: at least make sure the object exists locally.
    if (cd adder && git cat-file -e "$pin_sha" 2>/dev/null); then
        echo "[adder_pin] (offline) pin exists in submodule object DB — OK (upstream ancestry NOT verified)"
    else
        echo "[adder_pin] FAIL: pin $pin_sha is not a real commit (object missing AND fetch failed)"
        fail=1
    fi
fi

# --- 3. The pinned compiler is functional via the canonical import path. ---
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
