#!/usr/bin/env bash
# scripts/test_svc_logs.sh — per-service log capture, end to end.
#
# The init-side service supervisor (user/hamsh.ad's svc_* family)
# redirects every managed service's stdout AND stderr to
# /var/log/svc/<name>.log via DEVFD_FILE_APPEND. The path:
#
#   1. svc_start opens /var/log/svc/<name>.log with sys_openchan
#      mode=OPENCHAN_APPEND (tmpfs_open_for_append — no truncate).
#   2. The supervisor binds the resulting tmpfs slot at the spawned
#      child's /fd/1 (DEVFD_FILE_APPEND) and /fd/2 (DEVFD_DUP from
#      /fd/1 — devfd_dup propagates the append kind).
#   3. devfd_write for DEVFD_FILE_APPEND always lands at tmpfs_size
#      (write-at-EOF), so stdout and stderr never overwrite each
#      other and a `svc restart` appends to the same file instead of
#      truncating.
#
# This test boots the standard rc.boot path (which `svc start sshd`s
# during init), waits for the supervisor to install the log file,
# then drives a `svc restart sshd` and asserts:
#
#   1. /var/log/svc/sshd.log exists after boot and contains sshd's
#      startup marker ("[sshd] Hamnix SSH-2.0 server starting").
#   2. The supervisor's restart-separator banner is present.
#   3. After `svc restart sshd`, the BOTH old and new markers are
#      present in the SAME log file — proving append (not truncate).
#
# Driven via the shared _qemu_drive.sh harness: waits for hamsh's
# readiness marker, then feeds commands with the newline appended.

. "$(dirname "$0")/_build_lock.sh"
. "$(dirname "$0")/_qemu_drive.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf

echo "[test_svc_logs] (1/3) Build userland + initramfs (default /init shim)"
bash scripts/build_user.sh >/dev/null
bash scripts/build_modules.sh >/dev/null 2>&1 || true
python3 scripts/build_initramfs.py >/dev/null

echo "[test_svc_logs] (2/3) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal init/main.ad -o "$ELF" >/dev/null

LOG=$(mktemp /tmp/test-svc-logs.XXXXXX.log)
trap 'rm -f "$LOG"' EXIT

echo "[test_svc_logs] (3/3) Boot QEMU + drive svc log inspection"
set +e
# Generous timeout: boot + ~5 commands + their inter-command delays.
# The two `cat` reads of /var/log/svc/sshd.log dominate — sshd's
# startup banner lands well within the first 5 s of being supervised.
qemu_drive "$LOG" "$ELF" "[hamsh] M16.35 shell ready" 120 \
    -- "echo SVC_LOG_STAGE_INITIAL"                       2 \
       "cat /var/log/svc/sshd.log"                        3 \
       "echo SVC_LOG_STAGE_AFTER_FIRST"                   2 \
       "svc restart sshd"                                 5 \
       "echo SVC_LOG_STAGE_AFTER_RESTART"                 2 \
       "cat /var/log/svc/sshd.log"                        3 \
       "echo SVC_LOG_STAGE_FINAL"                         2 \
       "exit"                                             1
rc="$QEMU_DRIVE_RC"
set -e

echo "[test_svc_logs] --- captured output ---"
cat "$LOG"
echo "[test_svc_logs] --- end output ---"

fail=0

# 1. Shell came up.
if ! grep -F -q "[hamsh:stage-07] loop-enter" "$LOG"; then
    echo "[test_svc_logs] FAIL: hamsh never reached the interactive loop"
    exit 1
fi

# 2. After the first `cat`, the log contains sshd's startup marker.
# The marker comes from user/sshd.ad's main(): `[sshd] Hamnix
# SSH-2.0 server starting`. The supervisor's redirect must land
# BEFORE sshd writes its first byte for this to show up in the file
# (cooperative scheduler keeps the child STATE_READY until the
# supervisor finishes binding /fd/1+/fd/2).
first_cat=$(sed -n '/SVC_LOG_STAGE_INITIAL/,/SVC_LOG_STAGE_AFTER_FIRST/p' "$LOG")
if echo "$first_cat" | grep -F -q "Hamnix SSH-2.0 server starting"; then
    echo "[test_svc_logs] OK: /var/log/svc/sshd.log captured sshd stdout"
else
    echo "[test_svc_logs] MISS: sshd startup marker absent from log file"
    fail=1
fi

# 3. The supervisor's restart-separator banner is present. Format:
# `--- start sshd uptime=<Nms> restarts=<R> ---`. The first start
# emits one too (restarts=0); we just require the prefix to land.
if echo "$first_cat" | grep -E -q -- '--- start sshd uptime=[0-9]+ms restarts=[0-9]+ ---'; then
    echo "[test_svc_logs] OK: supervisor restart-separator banner present"
else
    echo "[test_svc_logs] MISS: '--- start sshd ...' banner not in log"
    fail=1
fi

# 4. After `svc restart sshd`, the BOTH old and new markers are still
# present in the file. Append-mode log capture means the new run's
# output joins the existing content rather than truncating it.
second_cat=$(sed -n '/SVC_LOG_STAGE_AFTER_RESTART/,/SVC_LOG_STAGE_FINAL/p' "$LOG")

# Count how many "Hamnix SSH-2.0 server starting" lines appear in
# the second read of the log. Pre-restart: 1. Post-restart: 2.
n_markers=$(echo "$second_cat" | grep -F -c "Hamnix SSH-2.0 server starting" \
            || true)
if [ "${n_markers:-0}" -ge 2 ]; then
    echo "[test_svc_logs] OK: post-restart log contains BOTH runs' markers" \
         "(found $n_markers Hamnix SSH-2.0 lines)"
else
    echo "[test_svc_logs] MISS: post-restart log shows only" \
         "$n_markers marker(s) — restart truncated the file?"
    fail=1
fi

# 5. The supervisor wrote at least TWO restart-separator banners after
# the restart (one from the initial start, one from `svc restart`).
n_banners=$(echo "$second_cat" \
            | grep -E -c -- '--- start sshd uptime=[0-9]+ms restarts=[0-9]+ ---' \
            || true)
if [ "${n_banners:-0}" -ge 2 ]; then
    echo "[test_svc_logs] OK: two restart-separator banners present" \
         "(found $n_banners)"
else
    echo "[test_svc_logs] MISS: only $n_banners separator banner(s)" \
         "after restart"
    fail=1
fi

# 6. Shell survived to the final marker.
if grep -F -q "SVC_LOG_STAGE_FINAL" "$LOG"; then
    echo "[test_svc_logs] OK: shell survived the whole sequence"
else
    echo "[test_svc_logs] MISS: SVC_LOG_STAGE_FINAL marker absent — shell died early"
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_svc_logs] FAIL (qemu rc=$rc)"
    exit 1
fi
echo "[test_svc_logs] PASS (qemu rc=$rc)"
