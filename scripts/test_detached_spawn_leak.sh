#!/usr/bin/env bash
# scripts/test_detached_spawn_leak.sh — detached (RFNOWAIT / `spawn detached`)
# task lifecycle regression test.
#
# REGRESSION GUARD (do not delete): a DETACHED task (rfork RFNOWAIT, the path
# hamsh's `spawn detached` and the desktop's fire-and-forget app launches use)
# self-reaped on exit by flipping its slot straight to STATE_FREE — but it
# could NOT free its own address space (it was still running on its own kstack
# under its own cr3), so kernel/sched/core.ad::task_exit_current freed the SLOT
# and leaked EVERYTHING ELSE: the ELF image region, the 32 MiB glibc brk
# reserve, the user stack, the kstack, the PML4 + private page tables, the mmap
# VMAs, and the cgroup pids charge (never uncharged). After a series of detached
# spawns the page / region pools and the cgroup pids budget bled out, so the
# next fork()/clone() ANYWHERE — including an innocent `enter linux {sh}`
# pipeline, or the desktop trying to relaunch hamedit / an app-menu entry —
# failed with -EAGAIN ("can't fork: Resource temporarily unavailable").
#
# The fix (kernel/sched/core.ad): a detached task is now published a normal
# STATE_EXITED zombie (detached==1) instead of self-freeing, and the new
# reap_orphan_zombies() — invoked at every fork (do_clone / do_rfork) right
# before a new task is allocated, and which calls the full COW-safe task_reap()
# — reclaims it. So a dead detached task's WHOLE address space + slot + cgroup
# charge come back exactly when the next spawn needs them.
#
# This test drives many `spawn detached` launches of /bin/hello in a single
# uninterrupted hamsh session, then a FINAL foreground spawn + marker, and
# asserts the session never wedged / ran out of slots and the final command
# still ran (i.e. detached resources were recycled, not leaked).

. "$(dirname "$0")/_build_lock.sh"
. "$(dirname "$0")/_qemu_drive.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf

echo "[test_detached_spawn_leak] (1/3) Build userland + initramfs"
bash scripts/build_user.sh >/dev/null
bash scripts/build_modules.sh >/dev/null 2>&1 || true
python3 scripts/build_initramfs.py >/dev/null

echo "[test_detached_spawn_leak] (2/3) Rebuild kernel image"
mkdir -p build
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal init/main.ad -o "$ELF" >/dev/null

LOG=$(mktemp /tmp/test-detached-spawn.XXXXXX.log)
trap 'rm -f "$LOG"' EXIT

# How many detached spawns to drive. Each leaked its whole address space under
# the old code; the sweep at fork time must recycle them so the run survives.
SPAWNS=40

# Define a namespace template, then fire SPAWNS detached /bin/hello launches.
# Each detached child runs /bin/hello and exits -> a detached zombie that the
# NEXT spawn's reap_orphan_zombies() must reclaim. A leak would surface as
# 'out of tasks' / 'command not found' or a wedge before the final marker.
CMDS=()
CMDS+=( 'sandbox = ns { }' 1 )
n=1
while [ "$n" -le "$SPAWNS" ]; do
    CMDS+=( 'spawn detached sandbox { /bin/hello }' 1 )
    n=$((n + 1))
done
# A final FOREGROUND spawn must still succeed after all the detached ones —
# this is the user-visible "the next launch still works" assertion.
CMDS+=( "/bin/hello" 1 )
CMDS+=( "echo DETACHED_LOOP_DONE" 2 )
CMDS+=( "exit" 1 )

echo "[test_detached_spawn_leak] (3/3) Boot QEMU + drive ${SPAWNS} detached spawns"
set +e
qemu_drive "$LOG" "$ELF" "[hamsh] M16.35 shell ready" 600 \
    -- "${CMDS[@]}"
rc="$QEMU_DRIVE_RC"
set -e

echo "[test_detached_spawn_leak] --- captured output (filtered) ---"
{ grep -a -E "/hello\]|DETACHED_LOOP_DONE|command not found|out of tasks|no free task slot|can't fork|Resource temporarily" "$LOG" \
    || true; } | sed 's/\x1b\[[0-9;]*[a-zA-Z]//g' | tr -d '\000' | head -120
echo "[test_detached_spawn_leak] --- end output ---"

fail=0

if ! grep -a -F -q "[hamsh] M16.35 shell ready" "$LOG"; then
    echo "[test_detached_spawn_leak] FAIL: hamsh never reached the interactive loop"
    exit 1
fi

outlines() { grep -a -vE 'hamsh\$|\] > ' "$LOG" 2>/dev/null || true; }

# 1. Never ran out of task slots (the reaped detached slots must recycle).
if outlines | grep -a -qE "out of tasks|no free task slot"; then
    echo "[test_detached_spawn_leak] FAIL: ran out of task slots (detached leak)"
    fail=1
else
    echo "[test_detached_spawn_leak] OK: no task-slot exhaustion"
fi

# 2. No fork ever returned -EAGAIN for want of memory/slots.
if outlines | grep -a -qE "can't fork|Resource temporarily"; then
    echo "[test_detached_spawn_leak] FAIL: a fork returned -EAGAIN (resource leak)"
    fail=1
else
    echo "[test_detached_spawn_leak] OK: no -EAGAIN fork failures"
fi

# 3. The FINAL foreground /bin/hello still ran after all the detached spawns.
if outlines | grep -a -q "/hello\] hello"; then
    echo "[test_detached_spawn_leak] OK: /bin/hello still launches after the detached storm"
else
    echo "[test_detached_spawn_leak] FAIL: /bin/hello never ran (spawn path broke)"
    fail=1
fi

# 4. The shell survived the whole loop and is still accepting commands.
if outlines | grep -a -q "DETACHED_LOOP_DONE"; then
    echo "[test_detached_spawn_leak] OK: shell survived the detached-spawn loop"
else
    echo "[test_detached_spawn_leak] FAIL: DETACHED_LOOP_DONE absent — shell wedged"
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_detached_spawn_leak] RESULT: FAIL"
    exit 1
fi
echo "[test_detached_spawn_leak] RESULT: PASS (qemu rc=$rc)"
