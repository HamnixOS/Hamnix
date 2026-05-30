#!/usr/bin/env bash
# scripts/test_spawn_stress.sh — large-binary spawn-reclaim regression.
#
# REGRESSION GUARD (do not weaken the spawn count): an interactive
# hamsh session used to wedge after only ~6 spawns of a LARGE external
# binary. Each foreground spawn (sys_spawn + waitpid + reap) carved a
# per-task ELF image region sized to the binary's whole PT_LOAD span
# (code + data + BSS). For a big native binary like `hpm` that span is
# ~14.7 MiB, allocated straight from the one-way memblock bump
# allocator with NO free path. The region was therefore leaked on every
# spawn; after ~6 the ~240 MiB pool was exhausted, the next sys_spawn's
# region alloc returned 0 -> ENOEXEC, and hamsh MISREPORTED the failure
# as "command not found: hpm" — even though /bin/hpm was right there and
# had run fine moments earlier.
#
# The fix (kernel/sched/core.ad::task_reap + mm/page_alloc.ad's
# region_alloc/region_free) gives the image region, the user stack, the
# kernel stack, the per-task PML4 and its private lower-level page
# tables a real reclaim path on the normal reap. A reaped large region
# is pooled by exact size and handed straight back to the next identical
# spawn, so the pool stays FLAT across an unbounded number of spawns.
#
# This test drives MANY more large-binary spawns than the pre-fix
# ceiling (32, vs the ~6 that used to exhaust RAM) in one uninterrupted
# hamsh session and asserts EVERY one ran — no "command not found", no
# "out of memory", no "out of tasks", no kernel fault — and that the
# shell survived to the final marker. It complements test_spawn_loop.sh
# (which stresses the task-SLOT pool with a tiny binary); this one
# stresses the page/region pool with a fat binary, which is where the
# real-world hpm-rollback wedge lived.
#
# Boot/drive harness modelled on scripts/test_spawn_loop.sh and
# scripts/test_hpm.sh.

. "$(dirname "$0")/_build_lock.sh"
. "$(dirname "$0")/_qemu_drive.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf

echo "[test_spawn_stress] (1/3) Build userland + initramfs"
bash scripts/build_user.sh >/dev/null
bash scripts/build_modules.sh >/dev/null 2>&1 || true
python3 scripts/build_initramfs.py >/dev/null

echo "[test_spawn_stress] (2/3) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal init/main.ad -o "$ELF" >/dev/null

LOG=$(mktemp /tmp/test-spawn-stress.XXXXXX.log)
trap 'rm -f "$LOG"' EXIT

# Spawn count. The pre-fix ceiling for a 14.7 MiB `hpm` image against a
# ~240 MiB pool was ~6 spawns; 32 is a wide margin that only passes if
# the region is actually being reclaimed and recycled per spawn.
SPAWNS=32

# `hpm list` with no repo refreshed prints "no packages installed" and
# exits 0 — a clean, cheap, real external-binary spawn of the FAT hpm
# image (the exact binary the hpm-rollback wedge spawned). After each
# spawn, an in-shell `echo STRESS_<n>` marker proves the shell was still
# alive and accepting commands at iteration <n>.
CMDS=()
n=1
while [ "$n" -le "$SPAWNS" ]; do
    CMDS+=( "hpm list" 2 )
    CMDS+=( "echo STRESS_${n}" 1 )
    n=$((n + 1))
done
CMDS+=( "echo STRESS_DONE" 2 )
CMDS+=( "exit" 1 )

echo "[test_spawn_stress] (3/3) Boot QEMU + drive ${SPAWNS} fat-binary spawns"
set +e
qemu_drive "$LOG" "$ELF" "[hamsh] M16.35 shell ready" 240 \
    -- "${CMDS[@]}"
rc="$QEMU_DRIVE_RC"
set -e

echo "[test_spawn_stress] --- captured output (filtered) ---"
grep -a -E "STRESS_|no packages installed|command not found|out of (tasks|memory)|cannot map|PANIC|panic:|TRAP:|BUG:" "$LOG" \
    | sed 's/\x1b\[[0-9;]*[a-zA-Z]//g' | tr -d '\000' | head -160
echo "[test_spawn_stress] --- end output ---"

fail=0

# 1. The shell came up.
if ! grep -a -F -q "[hamsh] M16.35 shell ready" "$LOG"; then
    echo "[test_spawn_stress] FAIL: hamsh never reached the interactive loop"
    echo "[test_spawn_stress] FAIL"
    exit 1
fi

# Hard fault gate — any kernel fault is an unconditional FAIL.
if grep -a -E -q "PANIC|panic:|TRAP:|BUG:" "$LOG"; then
    echo "[test_spawn_stress] FAIL: kernel fault during spawn stress"
    echo "[test_spawn_stress] FAIL"
    exit 1
fi

# Command OUTPUT lines only (drop the line-editor input echo, which
# carries a 'hamsh$' prompt prefix). Mirrors test_spawn_loop.sh.
outlines() { grep -a -vE 'hamsh\$|\] > ' "$LOG" 2>/dev/null || true; }

# 2. No spawn was ever reported as not-found (the symptom of a failed
#    sys_spawn from an exhausted region/page pool).
if outlines | grep -a -q "command not found"; then
    echo "[test_spawn_stress] FAIL: a spawn was 'command not found' (region/page leak)"
    fail=1
else
    echo "[test_spawn_stress] OK: no 'command not found' for any spawn"
fi

# 3. No out-of-memory / out-of-tasks / mapping failure.
if outlines | grep -a -E -q "out of memory|out of tasks|cannot map binary"; then
    echo "[test_spawn_stress] FAIL: sys_spawn ran out of a resource pool"
    fail=1
else
    echo "[test_spawn_stress] OK: no resource-exhaustion spawn errors"
fi

# 4. hpm actually ran many times. `hpm list` prints exactly one
#    "no packages installed" line per successful spawn.
hpm_runs=$(outlines | grep -a -c "no packages installed")
echo "[test_spawn_stress] hpm ran ${hpm_runs} times"
if [ "${hpm_runs:-0}" -ge "$SPAWNS" ]; then
    echo "[test_spawn_stress] OK: all ${SPAWNS} fat-binary spawns completed"
else
    echo "[test_spawn_stress] FAIL: only ${hpm_runs}/${SPAWNS} spawns completed"
    fail=1
fi

# 5. The shell reached the LAST iteration AND the final marker — proves
#    the region pool recycled the whole way, not just the first few.
if outlines | grep -a -q "STRESS_${SPAWNS}\b"; then
    echo "[test_spawn_stress] OK: reached STRESS_${SPAWNS} (well past the pre-fix ~6 ceiling)"
else
    echo "[test_spawn_stress] FAIL: never reached STRESS_${SPAWNS} marker"
    fail=1
fi
if outlines | grep -a -q "STRESS_DONE"; then
    echo "[test_spawn_stress] OK: shell survived the whole spawn stress"
else
    echo "[test_spawn_stress] FAIL: STRESS_DONE absent — shell wedged"
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_spawn_stress] FAIL (qemu rc=$rc)"
    exit 1
fi
echo "[test_spawn_stress] PASS (qemu rc=$rc)"
