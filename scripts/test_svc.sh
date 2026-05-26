#!/usr/bin/env bash
# scripts/test_svc.sh — init-side service supervisor, end to end.
#
# The supervisor lives in user/hamsh.ad (hamsh IS PID 1 via the
# /init shim). It owns /etc/svc/<name>.hamsh definitions plus a
# periodic reap-and-restart tick. `svc status / start / stop /
# restart / reload` are hamsh builtins. This test boots the standard
# rc.boot path (which now does `svc start sshd` instead of
# `spawn detached bootns { sshd }`) and asserts:
#
#   1. After boot, `svc status` shows sshd registered + running with
#      a pid > 0 and the .hamsh-declared exec line.
#   2. `svc status sshd` (single-service form) renders the same data.
#   3. `svc restart sshd` produces a NEW pid (different from the
#      pre-restart one) and the service is RUNNING afterward.
#
# Driven via the shared _qemu_drive.sh harness: waits for hamsh's
# readiness marker, then feeds commands with the newline appended.

. "$(dirname "$0")/_build_lock.sh"
. "$(dirname "$0")/_qemu_drive.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf

echo "[test_svc] (1/3) Build userland + initramfs (default /init shim)"
bash scripts/build_user.sh >/dev/null
bash scripts/build_modules.sh >/dev/null 2>&1 || true
python3 scripts/build_initramfs.py >/dev/null

echo "[test_svc] (2/3) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal init/main.ad -o "$ELF" >/dev/null

LOG=$(mktemp /tmp/test-svc.XXXXXX.log)
trap 'rm -f "$LOG"' EXIT

echo "[test_svc] (3/3) Boot QEMU + drive svc CLI"
set +e
# A generous overall timeout covers boot + the four commands + their
# inter-command delays (~16 s). 120 s is comfortable for a CI host.
qemu_drive "$LOG" "$ELF" "[hamsh] M16.35 shell ready" 120 \
    -- "echo SVC_STAGE_INITIAL"                       2 \
       "svc status"                                   3 \
       "echo SVC_STAGE_AFTER_STATUS"                  2 \
       "svc status sshd"                              3 \
       "echo SVC_STAGE_AFTER_SINGLE"                  2 \
       "svc restart sshd"                             5 \
       "echo SVC_STAGE_AFTER_RESTART"                 2 \
       "svc status sshd"                              3 \
       "echo SVC_STAGE_FINAL"                         2 \
       "exit"                                         1
rc="$QEMU_DRIVE_RC"
set -e

echo "[test_svc] --- captured output ---"
cat "$LOG"
echo "[test_svc] --- end output ---"

fail=0

# 1. The shell came up.
if ! grep -F -q "[hamsh:stage-07] loop-enter" "$LOG"; then
    echo "[test_svc] FAIL: hamsh never reached the interactive loop"
    exit 1
fi

# 2. rc.boot's `svc start sshd` produced a running sshd. The status
# line renders `name  state=running  ns=init  pid=<N>  ...` — we
# extract the FIRST `svc status` (between the INITIAL marker and the
# AFTER_STATUS marker) and assert sshd shows up as running with a
# pid > 0.
first_status=$(sed -n '/SVC_STAGE_INITIAL/,/SVC_STAGE_AFTER_STATUS/p' "$LOG")
if echo "$first_status" | grep -E -q 'sshd[[:space:]]+state=running[[:space:]]+ns=init'; then
    echo "[test_svc] OK: svc status shows sshd state=running ns=init"
else
    echo "[test_svc] MISS: svc status does not show sshd as running"
    fail=1
fi

# Capture sshd's pid from the first single-service status output.
single_status=$(sed -n '/SVC_STAGE_AFTER_STATUS/,/SVC_STAGE_AFTER_SINGLE/p' "$LOG")
pid_before=$(echo "$single_status" \
    | grep -E -o 'sshd[[:space:]]+state=running[[:space:]]+ns=init[[:space:]]+pid=[0-9]+' \
    | head -1 \
    | grep -E -o 'pid=[0-9]+' \
    | head -1 \
    | sed 's/pid=//')
if [ -n "${pid_before:-}" ] && [ "$pid_before" -gt 0 ]; then
    echo "[test_svc] OK: pre-restart sshd pid=$pid_before"
else
    echo "[test_svc] MISS: could not extract a positive sshd pid"
    fail=1
fi

# 3. The single-service form rendered the exec line.
if echo "$single_status" | grep -F -q "exec=/bin/sshd"; then
    echo "[test_svc] OK: svc status sshd shows the .hamsh-declared exec line"
else
    echo "[test_svc] MISS: exec= line absent from single-service status"
    fail=1
fi

# 4. After `svc restart sshd`, sshd is running with a DIFFERENT pid.
final_status=$(sed -n '/SVC_STAGE_AFTER_RESTART/,/SVC_STAGE_FINAL/p' "$LOG")
pid_after=$(echo "$final_status" \
    | grep -E -o 'sshd[[:space:]]+state=running[[:space:]]+ns=init[[:space:]]+pid=[0-9]+' \
    | head -1 \
    | grep -E -o 'pid=[0-9]+' \
    | head -1 \
    | sed 's/pid=//')
if [ -n "${pid_after:-}" ] && [ "$pid_after" -gt 0 ]; then
    echo "[test_svc] OK: post-restart sshd pid=$pid_after"
else
    echo "[test_svc] MISS: post-restart sshd is not running"
    fail=1
fi

if [ -n "${pid_before:-}" ] && [ -n "${pid_after:-}" ]; then
    if [ "$pid_before" -ne "$pid_after" ]; then
        echo "[test_svc] OK: svc restart produced a new pid" \
             "($pid_before -> $pid_after)"
    else
        echo "[test_svc] MISS: pid did not change across svc restart" \
             "($pid_before == $pid_after)"
        fail=1
    fi
fi

# 5. Shell survived to print the final marker.
if grep -F -q "SVC_STAGE_FINAL" "$LOG"; then
    echo "[test_svc] OK: shell survived the whole sequence"
else
    echo "[test_svc] MISS: SVC_STAGE_FINAL marker absent — shell died early"
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_svc] FAIL (qemu rc=$rc)"
    exit 1
fi
echo "[test_svc] PASS (qemu rc=$rc)"
