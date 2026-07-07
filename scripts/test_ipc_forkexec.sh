#!/usr/bin/env bash
# scripts/test_ipc_forkexec.sh -- inherited pipe/socketpair IPC across
# fork+execve (the Firefox parent<->content cross-process IPC shape).
#
# A static-PIE parent (u_ipc_forkexec) creates a pipe pair + an AF_UNIX
# socketpair, fork()s, and the child execve()s a DIFFERENT static-PIE
# image (u_ipc_child) that inherits those fds across the image swap. The
# two processes then round-trip a message BOTH directions over BOTH
# transports. This proves an fd inherited by fork() and carried through
# execve() references the SAME backing endpoint (pipe buffer /
# socketpair ring) as the parent -- the invariant a multi-process Linux
# app (Firefox, dbus, X clients) deadlocks on if it is broken.
#
# PASS markers (all four + child status=0):
#   "IPCFE: child got pipe msg=PING"
#   "IPCFE: child got sock msg=SPING"
#   "IPCFE: parent got pipe reply=PONG"
#   "IPCFE: parent got sock reply=SPONG"
#   "IPCFE: ALL PASS"

. "$(dirname "$0")/_build_lock.sh"
. "$(dirname "$0")/_qemu_drive.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

make -C tests/u-binary/src/ipc_child install >/dev/null 2>&1 || true
make -C tests/u-binary/src/ipc_forkexec install >/dev/null 2>&1 || true
[ -f tests/u-binary/u_ipc_forkexec ] || { echo "SKIP: parent fixture not built"; exit 0; }
[ -f tests/u-binary/u_ipc_child ]   || { echo "SKIP: child fixture not built"; exit 0; }

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf

echo "[ipcfe] build user + modules"
bash scripts/build_user.sh >/dev/null
bash scripts/build_modules.sh >/dev/null

echo "[ipcfe] embed ubin + hamsh init"
HAMNIX_EMBED_UBIN=1 INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py >/dev/null

echo "[ipcfe] build kernel"
python3 -m compiler.adder compile --target=x86_64-bare-metal init/main.ad -o "$ELF" >/dev/null

LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1 || true' EXIT

set +e
QEMU_EXTRA_ARGS="-enable-kvm -cpu host" \
qemu_drive "$LOG" "$ELF" "[hamsh] M16.35 shell ready" 120 \
    -- "u_ipc_forkexec" 10 \
       "exit" 1
rc="$QEMU_DRIVE_RC"
set -e

echo "[ipcfe] --- output ---"; cat "$LOG"; echo "[ipcfe] --- end ---"

fail=0
for m in \
    "IPCFE: child got pipe msg=PING" \
    "IPCFE: child got sock msg=SPING" \
    "IPCFE: parent got pipe reply=PONG" \
    "IPCFE: parent got sock reply=SPONG" \
    "IPCFE: ALL PASS"; do
    if grep -aF -q "$m" "$LOG"; then
        echo "[ipcfe] OK: $m"
    else
        echo "[ipcfe] MISS: $m"
        fail=1
    fi
done

grep -aiE "NX exec-fault|capturing core|code=139|coredump|IPCFE: FAIL" "$LOG" \
    && { echo "[ipcfe] FAULT/FAIL marker seen"; fail=1; } || true

echo "=== VERDICT ==="
if [ "$fail" -eq 0 ]; then
    echo "[ipcfe] PASS -- inherited pipe+socketpair share backing across fork+exec"
    exit 0
fi
echo "[ipcfe] FAIL (qemu rc=$rc)"
exit 1
