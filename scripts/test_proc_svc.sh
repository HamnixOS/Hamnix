#!/usr/bin/env bash
# scripts/test_proc_svc.sh — /proc/svc kernel mirror, end to end.
#
# Phase 6 of the service-supervisor work. The supervisor itself lives
# in user/hamsh.ad (hamsh IS PID 1 via the /init shim); its in-memory
# registry holds the live state. A new SYS_SVC_PUBLISH syscall ships
# each slot into a kernel-side mirror in fs/procfs.ad, which is what
# `cat /proc/svc/<name>` renders from. This test boots the standard
# rc.boot path (which runs `svc start sshd`) and asserts:
#
#   1. `cat /proc/svc` lists sshd with state=running and pid>0.
#   2. `cat /proc/svc/sshd` produces the SAME single-line shape as
#      `svc status sshd`, with state=running pid=N exec=/bin/sshd.
#   3. The pid in /proc/svc/sshd matches the pid svc reports — both
#      views are reading from the same publish stream.
#   4. `cat /proc/svc/bogus` cleanly reports "not registered" (not a
#      crash or a stale entry).
#
# Driven via the shared _qemu_drive.sh harness: waits for hamsh's
# readiness marker, then feeds commands with the newline appended.

. "$(dirname "$0")/_build_lock.sh"
. "$(dirname "$0")/_qemu_drive.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf

echo "[test_proc_svc] (1/3) Build userland + initramfs (default /init shim)"
bash scripts/build_user.sh >/dev/null
bash scripts/build_modules.sh >/dev/null 2>&1 || true
python3 scripts/build_initramfs.py >/dev/null

echo "[test_proc_svc] (2/3) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal init/main.ad -o "$ELF" >/dev/null

LOG=$(mktemp /tmp/test-proc-svc.XXXXXX.log)
trap 'rm -f "$LOG"' EXIT

echo "[test_proc_svc] (3/3) Boot QEMU + drive cat /proc/svc"
set +e
qemu_drive "$LOG" "$ELF" "[hamsh] M16.35 shell ready" 120 \
    -- "echo PROC_SVC_STAGE_INITIAL"                  2 \
       "svc status sshd"                              3 \
       "echo PROC_SVC_STAGE_AFTER_SVC_STATUS"         2 \
       "cat /proc/svc"                                3 \
       "echo PROC_SVC_STAGE_AFTER_LIST"               2 \
       "cat /proc/svc/sshd"                           3 \
       "echo PROC_SVC_STAGE_AFTER_ONE"                2 \
       "cat /proc/svc/bogus"                          3 \
       "echo PROC_SVC_STAGE_FINAL"                    2 \
       "exit"                                         1
rc="$QEMU_DRIVE_RC"
set -e

echo "[test_proc_svc] --- captured output ---"
cat "$LOG"
echo "[test_proc_svc] --- end output ---"

fail=0

# 1. The shell came up.
if ! grep -F -q "[hamsh:stage-07] loop-enter" "$LOG"; then
    echo "[test_proc_svc] FAIL: hamsh never reached the interactive loop"
    exit 1
fi

# Extract the svc-builtin pid (gold standard for what hamsh thinks).
svc_status_block=$(sed -n '/PROC_SVC_STAGE_INITIAL/,/PROC_SVC_STAGE_AFTER_SVC_STATUS/p' "$LOG")
svc_pid=$(echo "$svc_status_block" \
    | grep -E -o 'sshd[[:space:]]+state=running[[:space:]]+ns=init[[:space:]]+pid=[0-9]+' \
    | head -1 \
    | grep -E -o 'pid=[0-9]+' \
    | head -1 \
    | sed 's/pid=//')
if [ -n "${svc_pid:-}" ] && [ "$svc_pid" -gt 0 ]; then
    echo "[test_proc_svc] OK: svc status sshd reports pid=$svc_pid"
else
    echo "[test_proc_svc] MISS: could not extract sshd pid from svc status"
    fail=1
fi

# 2. cat /proc/svc lists sshd running.
proc_list_block=$(sed -n '/PROC_SVC_STAGE_AFTER_SVC_STATUS/,/PROC_SVC_STAGE_AFTER_LIST/p' "$LOG")
if echo "$proc_list_block" | grep -E -q 'sshd[[:space:]]+state=running[[:space:]]+ns=init'; then
    echo "[test_proc_svc] OK: /proc/svc lists sshd state=running ns=init"
else
    echo "[test_proc_svc] MISS: /proc/svc does not show sshd as running"
    fail=1
fi

# 3. cat /proc/svc/sshd shows state=running + pid + exec.
proc_one_block=$(sed -n '/PROC_SVC_STAGE_AFTER_LIST/,/PROC_SVC_STAGE_AFTER_ONE/p' "$LOG")
proc_pid=$(echo "$proc_one_block" \
    | grep -E -o 'sshd[[:space:]]+state=running[[:space:]]+ns=init[[:space:]]+pid=[0-9]+' \
    | head -1 \
    | grep -E -o 'pid=[0-9]+' \
    | head -1 \
    | sed 's/pid=//')
if [ -n "${proc_pid:-}" ] && [ "$proc_pid" -gt 0 ]; then
    echo "[test_proc_svc] OK: /proc/svc/sshd shows state=running pid=$proc_pid"
else
    echo "[test_proc_svc] MISS: /proc/svc/sshd does not show running pid"
    fail=1
fi
if echo "$proc_one_block" | grep -F -q "exec=/bin/sshd"; then
    echo "[test_proc_svc] OK: /proc/svc/sshd exposes the .hamsh exec line"
else
    echo "[test_proc_svc] MISS: exec= line absent from /proc/svc/sshd"
    fail=1
fi

# 4. The two views agree on the pid.
if [ -n "${svc_pid:-}" ] && [ -n "${proc_pid:-}" ]; then
    if [ "$svc_pid" = "$proc_pid" ]; then
        echo "[test_proc_svc] OK: svc status and /proc/svc agree on pid=$proc_pid"
    else
        echo "[test_proc_svc] MISS: pid mismatch — svc=$svc_pid /proc=$proc_pid"
        fail=1
    fi
fi

# 5. /proc/svc/bogus reports a clean not-registered message (no crash).
proc_bogus_block=$(sed -n '/PROC_SVC_STAGE_AFTER_ONE/,/PROC_SVC_STAGE_FINAL/p' "$LOG")
if echo "$proc_bogus_block" | grep -F -q "not registered"; then
    echo "[test_proc_svc] OK: /proc/svc/bogus reports not-registered"
else
    echo "[test_proc_svc] MISS: /proc/svc/bogus did not report not-registered"
    fail=1
fi

# 6. Shell survived to the final marker.
if grep -F -q "PROC_SVC_STAGE_FINAL" "$LOG"; then
    echo "[test_proc_svc] OK: shell survived the whole sequence"
else
    echo "[test_proc_svc] MISS: PROC_SVC_STAGE_FINAL absent — shell died early"
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_proc_svc] FAIL (qemu rc=$rc)"
    exit 1
fi
echo "[test_proc_svc] PASS (qemu rc=$rc)"
