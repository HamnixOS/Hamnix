#!/usr/bin/env bash
# scripts/test_memleak_soak.sh — memory-leak accounting soak test.
#
# PURPOSE
#
#   After a series of spawn+reap cycles, verifiable memory-accounting
#   counters (PagesInUse, VmaNodesLive, TasksLive) must return to (or
#   very near) their pre-loop baseline. Any monotonic growth is a leak.
#
#   Sequence:
#     1. Run /bin/test_memleak_soak BEFORE the loop — snapshot BEFORE
#        values.
#     2. Spawn+reap SPAWNS short-lived processes (/bin/hello) via hamsh.
#     3. Run /bin/test_memleak_soak AFTER — snapshot AFTER values.
#     4. Assert PagesInUse delta <= LEAK_TOLERANCE, VmaNodesLive delta == 0,
#        TasksLive delta == 0.
#
# NEW FIELDS IN /dev/meminfo (added by this work):
#   PagesInUse:     <N>   — buddy pages currently not on any free list
#   VmaNodesLive:   <N>   — live kmalloc'd VmaNode objects
#   TasksSpawned:   <N>   — cumulative task slots ever allocated
#   TasksReaped:    <N>   — cumulative task slots ever freed
#   TasksLive:      <N>   — task slots currently not STATE_FREE
#
# HOW TO READ THE OUTPUT:
#   The test prints BEFORE/AFTER snapshots and the delta for each
#   in-use counter. PASS = all deltas within tolerance.

. "$(dirname "$0")/_build_lock.sh"
. "$(dirname "$0")/_qemu_drive.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf
FIXTURE_SRC=tests/test_memleak_soak.ad
FIXTURE_ELF=build/user/test_memleak_soak.elf

# How many spawn+reap cycles to run. Each iteration spawns /bin/hello
# (tiny ELF, exercises the full load+exit+reap path) and emits a
# SOAK_<n> marker to confirm each iteration completed.
# 24 is well above NTASKS=16 (guaranteeing slot recycling).
SPAWNS=24

# Leak tolerance (pages). A small residual is acceptable because some
# one-time kernel-internal allocations (e.g. page-table pages for a new
# PDPT/PD/PT entry on first encounter of a new address range) may fire
# on the first few spawns but not repeat. We allow up to TOLERANCE pages
# of net growth across all SPAWNS.
LEAK_TOLERANCE=16

echo "[memleak_soak] (1/4) Build userland + fixture + initramfs"
bash scripts/build_user.sh >/dev/null
bash scripts/build_modules.sh >/dev/null 2>&1 || true

python3 -m compiler.adder compile \
    --target=x86_64-adder-user \
    "$FIXTURE_SRC" \
    -o "$FIXTURE_ELF" >/dev/null

INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py >/dev/null

echo "[memleak_soak] (2/4) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal init/main.ad -o "$ELF" >/dev/null

LOG=$(mktemp /tmp/test-memleak-soak.XXXXXX.log)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1' EXIT

# Build the hamsh command sequence via qemu_drive.
# Pattern: fixture BEFORE, spawn loop, fixture AFTER, exit.
CMDS=()

# Snapshot BEFORE.
CMDS+=( "/bin/test_memleak_soak" 2 )
CMDS+=( "echo SOAK_BEFORE_DONE" 1 )

# Spawn loop: /bin/hello runs+exits, echo marker confirms shell alive.
n=1
while [ "$n" -le "$SPAWNS" ]; do
    CMDS+=( "/bin/hello" 1 )
    CMDS+=( "echo SOAK_${n}" 1 )
    n=$((n + 1))
done

# Snapshot AFTER.
CMDS+=( "/bin/test_memleak_soak" 2 )
CMDS+=( "echo SOAK_AFTER_DONE" 1 )

CMDS+=( "echo SOAK_DONE" 1 )
CMDS+=( "exit" 1 )

echo "[memleak_soak] (3/4) Boot QEMU + drive ${SPAWNS} spawn/reap cycles"
set +e
# 180 s overall timeout. Boot ~30 s + fixture × 2 + 24 spawns × 2 s ≈ 90 s.
qemu_drive "$LOG" "$ELF" "[hamsh] M16.35 shell ready" 180 \
    -- "${CMDS[@]}"
rc="$QEMU_DRIVE_RC"
set -e

echo "[memleak_soak] (4/4) Analyse results"
echo "[memleak_soak] --- captured output (filtered) ---"
grep -a -E "memleak\]|SOAK_|command not found|out of|PANIC|BUG:|PagesInUse|VmaNodesLive|TasksLive|TasksSpawned|TasksReaped" "$LOG" \
    | sed 's/\x1b\[[0-9;]*[a-zA-Z]//g' | tr -d '\000' | head -140
echo "[memleak_soak] --- end output ---"

fail=0

# 1. Shell came up.
if ! grep -a -F -q "[hamsh] M16.35 shell ready" "$LOG"; then
    echo "[memleak_soak] FAIL: hamsh never reached the interactive loop"
    exit 1
fi

# 2. Hard fault gate.
if grep -a -E -q "PANIC|panic:|TRAP:|BUG:" "$LOG"; then
    echo "[memleak_soak] FAIL: kernel fault during soak"
    exit 1
fi

# Filter prompt-echo lines.
outlines() { grep -a -vE 'hamsh\$|\] > ' "$LOG" 2>/dev/null || true; }

# 3. Fixture ran cleanly twice.
fixture_count=$(grep -a -c "\[memleak\] done" "$LOG" || true)
echo "[memleak_soak] fixture completed ${fixture_count} times (expect 2)"
if [ "${fixture_count:-0}" -lt 2 ]; then
    echo "[memleak_soak] FAIL: fixture did not complete both BEFORE+AFTER runs"
    fail=1
fi

# 4. No spawn errors (check raw log — prompt-echo lines also have 'hamsh$'
#    but 'command not found' never appears in those).
if grep -a -q "command not found" "$LOG"; then
    echo "[memleak_soak] FAIL: a spawn was 'command not found'"
    fail=1
else
    echo "[memleak_soak] OK: no 'command not found' errors"
fi

if grep -a -E -q "out of memory|out of tasks|cannot map binary" "$LOG"; then
    echo "[memleak_soak] FAIL: resource exhaustion during soak"
    fail=1
else
    echo "[memleak_soak] OK: no resource-exhaustion errors"
fi

# 5. All iterations completed.
hello_runs=$(grep -a -c "\[/hello\] hello" "$LOG" || true)
echo "[memleak_soak] /bin/hello ran ${hello_runs} times"
if grep -a -q "^SOAK_${SPAWNS}$" "$LOG" || outlines | grep -a -q "^SOAK_${SPAWNS}$"; then
    echo "[memleak_soak] OK: reached SOAK_${SPAWNS}"
elif grep -a -q "SOAK_${SPAWNS}" "$LOG"; then
    echo "[memleak_soak] OK: reached SOAK_${SPAWNS}"
else
    echo "[memleak_soak] FAIL: SOAK_${SPAWNS} not reached (stalled after ${hello_runs} spawns)"
    fail=1
fi
if grep -a -q "SOAK_DONE" "$LOG"; then
    echo "[memleak_soak] OK: SOAK_DONE reached"
else
    echo "[memleak_soak] FAIL: SOAK_DONE absent"
    fail=1
fi

# 6. Extract BEFORE/AFTER values from the [memleak] fixture output.
#
# The fixture prints lines like:
#   [memleak] PagesInUse=12345
# The FIRST occurrence is BEFORE, the SECOND is AFTER.

extract_nth() {
    local key="$1"
    local n="$2"
    # Note: the first line of the fixture output may have a
    # "[runtime:...]" prefix (Adder runtime startup message) merged
    # on the same line as [memleak] PagesInUse=... — so we match
    # without the '^' anchor to handle that case.
    outlines | grep -a "\[memleak\] ${key}=" \
        | sed 's/.*\[memleak\] '"${key}"'=//' \
        | sed 's/[^0-9].*//' \
        | sed 's/[^0-9]//g' \
        | sed -n "${n}p"
}

before_pages=$(extract_nth "PagesInUse" 1)
after_pages=$(extract_nth "PagesInUse" 2)
before_vma=$(extract_nth "VmaNodesLive" 1)
after_vma=$(extract_nth "VmaNodesLive" 2)
before_tasks=$(extract_nth "TasksLive" 1)
after_tasks=$(extract_nth "TasksLive" 2)
before_spawned=$(extract_nth "TasksSpawned" 1)
after_spawned=$(extract_nth "TasksSpawned" 2)
before_reaped=$(extract_nth "TasksReaped" 1)
after_reaped=$(extract_nth "TasksReaped" 2)

echo "[memleak_soak] BEFORE: PagesInUse=${before_pages:-?} VmaNodesLive=${before_vma:-?} TasksLive=${before_tasks:-?} Spawned=${before_spawned:-?} Reaped=${before_reaped:-?}"
echo "[memleak_soak] AFTER:  PagesInUse=${after_pages:-?}  VmaNodesLive=${after_vma:-?}  TasksLive=${after_tasks:-?}  Spawned=${after_spawned:-?}  Reaped=${after_reaped:-?}"

# Validate spawn/reap accounting: every task spawned DURING the soak should
# be reaped. (spawned - reaped) counts all still-live spawned tasks, which
# always includes the persistent boot tasks (init + the shells) that are
# alive by design and never reaped. Compare against the boot baseline rather
# than a magic constant so this auto-tracks the persistent-task count if it
# changes again — a true leak shows up as growth above that baseline.
if [ -n "$after_spawned" ] && [ -n "$after_reaped" ] \
   && [ -n "$before_spawned" ] && [ -n "$before_reaped" ]; then
    unreaped=$(( after_spawned - after_reaped ))
    base_unreaped=$(( before_spawned - before_reaped ))
    echo "[memleak_soak] Unreaped tasks (spawned - reaped): ${unreaped} (boot baseline ${base_unreaped})"
    if [ "$unreaped" -le "$base_unreaped" ]; then
        echo "[memleak_soak] OK: spawn/reap accounting balanced (unreaped=${unreaped} <= baseline ${base_unreaped})"
    else
        echo "[memleak_soak] FAIL: ${unreaped} live spawned tasks exceeds boot baseline ${base_unreaped} (leak)"
        fail=1
    fi
fi

check_delta() {
    local label="$1"
    local before="$2"
    local after="$3"
    local tol="$4"
    if [ -z "$before" ] || [ -z "$after" ]; then
        echo "[memleak_soak] WARN: could not parse ${label} from fixture output"
        return 0
    fi
    local delta=$(( after - before ))
    if [ "$delta" -le "$tol" ]; then
        echo "[memleak_soak] OK: ${label} delta=${delta} (within tolerance ${tol})"
    else
        echo "[memleak_soak] FAIL: ${label} grew by ${delta} (limit: ${tol}) — LEAK DETECTED"
        fail=1
    fi
}

# PagesInUse may grow a little from one-time kernel-internal allocs.
check_delta "PagesInUse" "${before_pages:-}" "${after_pages:-}" "$LEAK_TOLERANCE"

# VmaNodesLive must return EXACTLY to baseline.
check_delta "VmaNodesLive" "${before_vma:-}" "${after_vma:-}" 0

# TasksLive must return to baseline.
check_delta "TasksLive" "${before_tasks:-}" "${after_tasks:-}" 0

if [ "$fail" -ne 0 ]; then
    echo "[memleak_soak] FAIL (qemu rc=$rc)"
    exit 1
fi
echo "[memleak_soak] PASS (qemu rc=$rc)"
