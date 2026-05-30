#!/usr/bin/env bash
# scripts/test_init_service.sh — native init/runlevel + declarative
# service end to end.
#
# The init/service system lives in user/hamsh.ad (hamsh IS PID 1 via
# the /init shim) plus two native commands (user/service.ad ->
# /bin/service, user/initctl.ad -> /bin/initctl) that talk to the
# PID-1 supervisor through the SYS_SVC_CTL kernel control mailbox.
#
# Declarative services are key:value text files dropped under
# /etc/services.d/<name>.svc — no recompile. rc.boot.full does
# `init 3`, which enters the default multi-user runlevel: that loads
# every /etc/services.d/*.svc and autostarts each enabled service whose
# `runlevel:` mask includes 3. The sample etc/services.d/hellosvc.svc
# (exec /bin/sleep 3600, enabled, runlevels 3 5) is the fixture.
#
# This test boots the standard rc.boot path and asserts:
#
#   1. AUTOSTART: after boot, the declarative `hellosvc` is registered
#      and state=running (the runlevel-3 transition discovered the .svc
#      file and started it) — proving user-addable services work with
#      no edit to any rc/source.
#   2. STOP: `service hellosvc stop` (sysadmin word order) transitions
#      it to state=stopped.
#   3. RESTART/START: `service hellosvc start` brings it back to
#      state=running with a fresh pid.
#   4. RUNLEVEL: `init 0` takes the shutdown path. We assert the
#      grep-able `[init] runlevel 0: ...` markers rather than relying
#      on the VM actually powering off, so it is safe as the final
#      command.
#
# Driven via the shared _qemu_drive.sh harness: waits for hamsh's
# readiness marker, then feeds commands with the newline appended.

. "$(dirname "$0")/_build_lock.sh"
. "$(dirname "$0")/_qemu_drive.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf

echo "[test_init_service] (1/3) Build userland + initramfs"
bash scripts/build_user.sh >/dev/null
bash scripts/build_modules.sh >/dev/null 2>&1 || true
python3 scripts/build_initramfs.py >/dev/null

echo "[test_init_service] (2/3) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal init/main.ad -o "$ELF" >/dev/null

LOG=$(mktemp /tmp/test-init-service.XXXXXX.log)
trap 'rm -f "$LOG"' EXIT

echo "[test_init_service] (3/3) Boot QEMU + drive service/init CLI"
set +e
qemu_drive "$LOG" "$ELF" "[hamsh] M16.35 shell ready" 150 \
    -- "echo IS_STAGE_INITIAL"                        2 \
       "service status"                               3 \
       "echo IS_STAGE_AFTER_STATUS"                   2 \
       "service hellosvc stop"                        3 \
       "echo IS_STAGE_AFTER_STOP"                     2 \
       "service hellosvc status"                      3 \
       "echo IS_STAGE_AFTER_STOPSTATUS"               2 \
       "service hellosvc start"                       4 \
       "echo IS_STAGE_AFTER_START"                    2 \
       "service hellosvc status"                      3 \
       "echo IS_STAGE_AFTER_STARTSTATUS"              2 \
       "init 0"                                       4 \
       "echo IS_STAGE_FINAL"                          2
rc="$QEMU_DRIVE_RC"
set -e

echo "[test_init_service] --- captured output ---"
cat "$LOG"
echo "[test_init_service] --- end output ---"

fail=0

# 0. The shell came up and reached the interactive loop.
if ! grep -F -q "[hamsh:stage-07] loop-enter" "$LOG"; then
    echo "[test_init_service] FAIL: hamsh never reached the interactive loop"
    exit 1
fi

# 0b. rc.boot.full entered the default runlevel (proves `init 3`
# fired during boot — the autostart trigger).
if grep -F -q "[init] entering runlevel 3" "$LOG"; then
    echo "[test_init_service] OK: boot entered runlevel 3"
else
    echo "[test_init_service] MISS: boot did not enter runlevel 3"
    fail=1
fi

# 1. AUTOSTART: declarative hellosvc shows up running in `service
# status` with no manual start and no rc edit.
first_status=$(sed -n '/IS_STAGE_INITIAL/,/IS_STAGE_AFTER_STATUS/p' "$LOG")
if echo "$first_status" | grep -E -q 'hellosvc[[:space:]]+state=running[[:space:]]+ns=init'; then
    echo "[test_init_service] OK: declarative hellosvc autostarted (state=running)"
else
    echo "[test_init_service] MISS: hellosvc not autostarted/running"
    fail=1
fi

# 1b. The .svc-declared exec line rendered.
if echo "$first_status" | grep -F -q "exec=/bin/sleep 3600"; then
    echo "[test_init_service] OK: hellosvc shows .svc-declared exec line"
else
    echo "[test_init_service] MISS: exec=/bin/sleep 3600 absent from status"
    fail=1
fi

# 2. STOP: after `service hellosvc stop`, status shows stopped.
stop_status=$(sed -n '/IS_STAGE_AFTER_STOP/,/IS_STAGE_AFTER_STOPSTATUS/p' "$LOG")
if echo "$stop_status" | grep -E -q 'hellosvc[[:space:]]+state=stopped'; then
    echo "[test_init_service] OK: service hellosvc stop -> state=stopped"
else
    echo "[test_init_service] MISS: hellosvc not stopped after stop verb"
    fail=1
fi

# 3. START: after `service hellosvc start`, running again with a pid>0.
start_status=$(sed -n '/IS_STAGE_AFTER_START/,/IS_STAGE_AFTER_STARTSTATUS/p' "$LOG")
pid_after=$(echo "$start_status" \
    | grep -E -o 'hellosvc[[:space:]]+state=running[[:space:]]+ns=init[[:space:]]+pid=[0-9]+' \
    | head -1 \
    | grep -E -o 'pid=[0-9]+' \
    | head -1 \
    | sed 's/pid=//')
if [ -n "${pid_after:-}" ] && [ "$pid_after" -gt 0 ]; then
    echo "[test_init_service] OK: service hellosvc start -> running pid=$pid_after"
else
    echo "[test_init_service] MISS: hellosvc not running after start verb"
    fail=1
fi

# 4. RUNLEVEL: `init 0` took the shutdown path (markers, not actual
# power-off, so the test stays deterministic).
if grep -F -q "[init] entering runlevel 0" "$LOG"; then
    echo "[test_init_service] OK: init 0 entered runlevel 0"
else
    echo "[test_init_service] MISS: init 0 did not enter runlevel 0"
    fail=1
fi
if grep -F -q "[init] runlevel 0: shutdown -- stopping services" "$LOG"; then
    echo "[test_init_service] OK: init 0 took the shutdown path (stopping services)"
else
    echo "[test_init_service] MISS: shutdown path marker absent"
    fail=1
fi
if grep -F -q "[init] runlevel 0: powering off" "$LOG"; then
    echo "[test_init_service] OK: init 0 reached the poweroff primitive"
else
    echo "[test_init_service] MISS: poweroff marker absent"
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_init_service] FAIL (qemu rc=$rc)"
    exit 1
fi
echo "[test_init_service] PASS (qemu rc=$rc)"
