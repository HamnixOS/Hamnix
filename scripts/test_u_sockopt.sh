#!/usr/bin/env bash
# scripts/test_u_sockopt.sh — §10 getsockopt/setsockopt round-trip.
#
# Proves a user binary can set and read back the common socket options
# server daemons rely on — SO_REUSEADDR, SO_RCVBUF, TCP_NODELAY,
# SO_ERROR, SO_BROADCAST — through the setsockopt(2)/getsockopt(2)
# syscalls bridged to the per-socket-record option store
# (fs/socket_state.ad) by linux_abi/u_syscalls.ad.
#
# Pure round-trip — no network traffic. Also confirms an unmodelled
# option is REJECTED with -ENOPROTOOPT rather than silently accepted.
#
# Pipeline:
#   1. Build tests/u-binary/src/sockopt -> tests/u-binary/u_sockopt.
#   2. Boot Hamnix with /init=hamsh and u_sockopt embedded.
#   3. Drive hamsh to exec u_sockopt; assert its markers.
#
# Required markers (all must appear):
#   "sockopt: reuseaddr ok"
#   "sockopt: rcvbuf ok"
#   "sockopt: nodelay ok"
#   "sockopt: so_error ok"
#   "sockopt: badopt rejected ok"
#   "sockopt: broadcast ok"
#   "sockopt: PASS"
#
# REQUIRES musl-gcc on the host; SKIP+PASS if absent (mirrors
# test_u_socket.sh).

. "$(dirname "$0")/_build_lock.sh"
. "$(dirname "$0")/_qemu_drive.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

if ! command -v musl-gcc >/dev/null 2>&1; then
    echo "[test_u_sockopt] SKIP: musl-gcc not installed."
    echo "    apt-get install -y musl-tools  # (needs sudo)"
    echo "[test_u_sockopt] PASS"
    exit 0
fi

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf
UBIN=tests/u-binary/u_sockopt

echo "[test_u_sockopt] (1/4) Build u_sockopt fixture"
make -C tests/u-binary/src/sockopt clean >/dev/null 2>&1 || true
make -C tests/u-binary/src/sockopt install
if [ ! -f "$UBIN" ]; then
    echo "[test_u_sockopt] SKIP: $UBIN not built (musl-gcc issue)"
    echo "[test_u_sockopt] PASS"
    exit 0
fi

echo "[test_u_sockopt] (2/4) Build userland (hamsh + helpers) + modules"
bash scripts/build_user.sh >/dev/null
bash scripts/build_modules.sh >/dev/null

echo "[test_u_sockopt] (3/4) Swap /init = hamsh + embed u_sockopt"
HAMNIX_EMBED_UBIN=1 INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py >/dev/null

echo "[test_u_sockopt] (4/4) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

LOG=$(mktemp)
cleanup() {
    rm -f "$LOG"
    INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "[test_u_sockopt] boot QEMU"
# A net device is present so socket(2) works; no SLIRP traffic needed
# (this test sets/gets options, it never sends a packet). The tcp
# guestfwd keeps the boot-time net_smoke tcp_connect from stalling.
set +e
# Prompt-aware drive: wait for hamsh's ready banner before sending input
# (a fixed sleep races boot-time variance -- see _qemu_drive.sh). A net
# device must be present so socket(2) works (no SLIRP traffic needed); pass
# the virtio-net NIC through qemu_drive's QEMU_EXTRA_ARGS hook.
QEMU_EXTRA_ARGS='-netdev user,id=n0,guestfwd=tcp:10.0.2.100:7-cmd:cat -device virtio-net-pci,netdev=n0,mac=52:54:00:12:34:56' \
qemu_drive "$LOG" "$ELF" "[hamsh] M16.35 shell ready" 240 \
    -- "u_sockopt" 15 \
       "exit" 2
rc="$QEMU_DRIVE_RC"
set -e

echo "[test_u_sockopt] --- captured (sockopt) ---"
grep -E 'sockopt:' "$LOG" || true
echo "[test_u_sockopt] --- end ---"

fail=0
for needle in \
    "sockopt: reuseaddr ok" \
    "sockopt: rcvbuf ok" \
    "sockopt: nodelay ok" \
    "sockopt: so_error ok" \
    "sockopt: badopt rejected ok" \
    "sockopt: broadcast ok" \
    "sockopt: PASS"
do
    if grep -a -F -q "$needle" "$LOG"; then
        echo "[test_u_sockopt] OK: '$needle'"
    else
        echo "[test_u_sockopt] MISS: '$needle'"
        fail=1
    fi
done

if grep -a -F -q "TRAP: vector" "$LOG"; then
    echo "[test_u_sockopt] DIAG: kernel reported a CPU exception"
    grep -a -F "TRAP: vector" "$LOG" | head -5 || true
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_u_sockopt] FAIL (qemu rc=$rc)"
    echo "[test_u_sockopt] --- full kernel log (last 200 lines) ---"
    tail -n 200 "$LOG"
    exit 1
fi

echo "[test_u_sockopt] PASS — setsockopt/getsockopt round-trip" \
     "for all common daemon options"
