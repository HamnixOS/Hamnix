#!/usr/bin/env bash
# scripts/ci_run_battery_shard.sh — run one round-robin shard of the
# bare-metal regression battery (scripts/ci_battery_manifest.txt).
#
# WHY: 56 pure-TCG QEMU boots run serially need ~75 min and blew past the
# 40-min job budget on GitHub's KVM-less runners, so the whole battery went
# permanently red — zero regression signal on every push. The CI job now
# fans the manifest out across a matrix of parallel runners; each invokes
# this script with its SHARD index and the total NSHARDS. Round-robin
# (index % NSHARDS) balances load: the manifest is fast→slow, so contiguous
# slices would pile every slow gate into the last shard.
#
# Usage:   SHARD=1 NSHARDS=8 bash scripts/ci_run_battery_shard.sh
#   or:    bash scripts/ci_run_battery_shard.sh <shard> <nshards>
# SHARD is 1-based. Exit 0 iff every gate in the shard passed (a wrapped
# gate that reports INCONCLUSIVE via ci_run_gate.sh is a non-failing
# warning, exactly as in the old per-step battery).
set -uo pipefail

PROJ_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJ_ROOT"

SHARD="${1:-${SHARD:-1}}"
NSHARDS="${2:-${NSHARDS:-1}}"
MANIFEST="${BATTERY_MANIFEST:-scripts/ci_battery_manifest.txt}"

if ! [[ "$SHARD" =~ ^[0-9]+$ ]] || ! [[ "$NSHARDS" =~ ^[0-9]+$ ]] \
   || [ "$SHARD" -lt 1 ] || [ "$NSHARDS" -lt 1 ] || [ "$SHARD" -gt "$NSHARDS" ]; then
    echo "[battery-shard] usage: SHARD (1..NSHARDS) NSHARDS >= 1 (got SHARD=$SHARD NSHARDS=$NSHARDS)" >&2
    exit 2
fi
if [ ! -f "$MANIFEST" ]; then
    echo "[battery-shard] manifest not found: $MANIFEST" >&2
    exit 2
fi

# Read the manifest, dropping blank lines and # comments.
mapfile -t GATES < <(grep -vE '^[[:space:]]*(#|$)' "$MANIFEST")
total="${#GATES[@]}"
if [ "$total" -eq 0 ]; then
    echo "[battery-shard] manifest is empty" >&2
    exit 2
fi

echo "[battery-shard] shard $SHARD/$NSHARDS over $total gates (round-robin)"

fail=0
ran=0
i=0
while [ "$i" -lt "$total" ]; do
    # 1-based round-robin: gate i belongs to shard (i % NSHARDS)+1.
    if [ $(( i % NSHARDS + 1 )) -eq "$SHARD" ]; then
        cmd="${GATES[$i]}"
        ran=$(( ran + 1 ))
        echo "::group::[$SHARD/$NSHARDS] $cmd"
        # Each gate already tees its own /tmp/<name>.log; here we just run it
        # and let stdout/stderr flow to the shard log. A gate's own exit code
        # decides PASS/FAIL (ci_run_gate.sh maps INCONCLUSIVE→0 warning).
        if eval "$cmd"; then
            echo "PASS $cmd"
        else
            echo "FAIL $cmd (exit $?)"
            fail=1
        fi
        echo "::endgroup::"
    fi
    i=$(( i + 1 ))
done

echo "[battery-shard] shard $SHARD/$NSHARDS ran $ran gates; fail=$fail"
exit "$fail"
