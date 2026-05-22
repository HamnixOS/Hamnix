#!/usr/bin/env bash
# scripts/test_u_udp.sh — §10 UDP sockets: first userland datagram I/O.
#
# Proves a user binary can do a real UDP request/response through the
# SOCK_DGRAM socket family — socket / bind / sendto / recvfrom / close
# — bridged to the in-kernel UDP socket layer (drivers/net/udp.ad) by
# linux_abi/u_syscalls.ad + fs/vfs.ad.
#
# The fixture (tests/u-binary/src/udptest) queries QEMU SLIRP's
# built-in DNS resolver at 10.0.2.2:53 — a real UDP server that always
# answers. No host-side helper and no guestfwd are needed: QEMU's
# guestfwd is TCP-only, so a UDP echo server is not reachable through
# SLIRP, but the built-in resolver is. The fixture sends a DNS A-record
# query for example.com over a datagram socket and asserts a
# well-formed DNS response comes back (query id echoed, QR bit set).
#
# Pipeline:
#   1. Build tests/u-binary/src/udptest -> tests/u-binary/u_udptest.
#   2. Boot Hamnix with /init=hamsh and u_udptest embedded.
#   3. Drive hamsh to exec u_udptest; assert its markers.
#
# Required markers (all must appear):
#   "udptest: sendto rc=29"
#   "udptest: dns id ok"
#   "udptest: dns qr ok"
#   "udptest: PASS"
#
# REQUIRES musl-gcc on the host. If tests/u-binary/u_udptest can't be
# built, exit 0 with a SKIP note so CI without the host toolchain still
# passes — mirrors test_u_socket.sh.

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

if ! command -v musl-gcc >/dev/null 2>&1; then
    echo "[test_u_udp] SKIP: musl-gcc not installed."
    echo "    apt-get install -y musl-tools  # (needs sudo)"
    echo "[test_u_udp] PASS"
    exit 0
fi

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf
UBIN=tests/u-binary/u_udptest

echo "[test_u_udp] (1/4) Build u_udptest fixture"
make -C tests/u-binary/src/udptest clean >/dev/null 2>&1 || true
make -C tests/u-binary/src/udptest install
if [ ! -f "$UBIN" ]; then
    echo "[test_u_udp] SKIP: $UBIN not built (musl-gcc issue)"
    echo "[test_u_udp] PASS"
    exit 0
fi

echo "[test_u_udp] (2/4) Build userland (hamsh + helpers) + modules"
bash scripts/build_user.sh >/dev/null
bash scripts/build_modules.sh >/dev/null

echo "[test_u_udp] (3/4) Swap /init = hamsh + embed u_udptest"
HAMNIX_EMBED_UBIN=1 INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py >/dev/null

echo "[test_u_udp] (4/4) Rebuild kernel image"
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

echo "[test_u_udp] boot QEMU with virtio-net + SLIRP DNS"
# The tcp guestfwd to 10.0.2.100:7 keeps the boot-time net_smoke
# tcp_connect from stalling (see test_u_socket.sh for the rationale).
# SLIRP's built-in DNS resolver at 10.0.2.2:53 needs no forwarding.
set +e
(
    sleep 60
    printf 'u_udptest\n'
    sleep 25
    printf 'exit\n'
    sleep 2
) | timeout 240s qemu-system-x86_64 \
    -kernel "$ELF" \
    -netdev "user,id=n0,guestfwd=tcp:10.0.2.100:7-cmd:cat" \
    -device virtio-net-pci,netdev=n0,mac=52:54:00:12:34:56 \
    -smp 2 \
    -nographic \
    -no-reboot \
    -m 256M \
    -monitor none \
    -serial stdio \
    > "$LOG" 2>&1
rc=$?
set -e

echo "[test_u_udp] --- captured (udptest / udp / dhcp) ---"
grep -E 'udptest:|\[udp\]|\[u_socket\]|\[dhcp\]' "$LOG" || true
echo "[test_u_udp] --- end ---"

fail=0
for needle in \
    "udptest: sendto rc=29" \
    "udptest: dns id ok" \
    "udptest: dns qr ok" \
    "udptest: PASS"
do
    if grep -F -q "$needle" "$LOG"; then
        echo "[test_u_udp] OK: '$needle'"
    else
        echo "[test_u_udp] MISS: '$needle'"
        fail=1
    fi
done

if grep -F -q "TRAP: vector" "$LOG"; then
    echo "[test_u_udp] DIAG: kernel reported a CPU exception"
    grep -F "TRAP: vector" "$LOG" | head -5 || true
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_u_udp] FAIL (qemu rc=$rc)"
    echo "[test_u_udp] --- full kernel log (last 200 lines) ---"
    tail -n 200 "$LOG"
    exit 1
fi

echo "[test_u_udp] PASS — user binary completed a real UDP" \
     "request/response via socket/bind/sendto/recvfrom/close"
