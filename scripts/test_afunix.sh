#!/usr/bin/env bash
# scripts/test_afunix.sh -- Linux AF_UNIX (local) domain sockets.
#
# Real Linux software (systemd notify, dbus, X11, journald, ssh-agent,
# countless daemons) rendezvous over AF_UNIX sockets: socketpair(2) for a
# pre-connected fd pair, or bind/listen/accept/connect over a filesystem
# pathname (or the Linux abstract namespace). The implementation lives in
# linux_abi/u_unixsock.ad and is wired into the Linux-ABI socket dispatch
# (linux_abi/u_syscalls.ad) as a sibling of the AF_INET family: socket /
# bind / listen / connect / accept / send / recv / sendto / recvfrom /
# socketpair / read / write / close all recognise an AF_UNIX fd and route
# to the in-kernel byte conduit instead of the TCP/UDP bridge.
#
# This test boots the kernel once with /etc/afunix-test planted
# (ENABLE_AFUNIX_TEST=1); init/main.ad's afunix gate (boot:37.afunix)
# calls afunix_selftest() (linux_abi/u_unixsock.ad), which exercises every
# primitive directly in boot context (driving the same conduit / name-
# registry / accept-queue code the syscall entry points call):
#
#   * socketpair round-trip: write one end, read the other, BOTH
#     directions.
#   * a bound-name STREAM listen/connect/accept then byte exchange both
#     ways; an accepted-peer close yields EOF on the client read.
#   * abstract-namespace bind + connect (and proof that an identically-
#     named PATHNAME socket does NOT match the abstract one).
#   * ECONNREFUSED when connecting with no listener.
#   * EADDRINUSE on a double bind of the same name.
#   * SOCK_DGRAM sendto/recvfrom by bound name, with EAGAIN on an empty
#     queue.
#
# Pass marker:  [afunix] PASS
# Fail marker:  [afunix] FAIL

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

export HAMNIX_BUILD_LOCK_TIMEOUT=900

ELF=build/hamnix-kernel.elf

echo "[test_afunix] (1/3) Build userland (init)"
bash scripts/build_user.sh >/dev/null

echo "[test_afunix] (2/3) Build kernel with /etc/afunix-test marker"
INIT_ELF=build/user/init.elf ENABLE_AFUNIX_TEST=1 \
    python3 scripts/build_initramfs.py >/dev/null
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1 || true' EXIT

echo "[test_afunix] (3/3) Boot QEMU and run the AF_UNIX self-test"
set +e
timeout 180s qemu-system-x86_64 \
    -kernel "$ELF" \
    -smp 1 \
    -nographic \
    -no-reboot \
    -m 256M \
    -monitor none \
    -serial stdio \
    </dev/null > "$LOG" 2>&1
rc=$?
set -e

echo "[test_afunix] --- AF_UNIX self-test output ---"
grep -aE "\[afunix\]" "$LOG" || true
echo "[test_afunix] --- end ---"

fail=0

if [ "$rc" -ne 0 ] && [ "$rc" -ne 124 ]; then
    echo "[test_afunix] FAIL: qemu exited rc=$rc" >&2
    fail=1
fi

# An explicit internal failure is fatal.
if grep -aqF "[afunix] FAIL" "$LOG"; then
    echo "[test_afunix] FAIL: kernel self-test reported a failure" >&2
    grep -aF "[afunix] FAIL" "$LOG" | head -5 || true
    fail=1
fi

# The kernel prints exactly "[afunix] PASS" on its own line (after an
# optional "[NNNNNN] " printk timestamp prefix) only when EVERY assertion
# held.
if grep -aqE '(^|\] )\[afunix\] PASS$' "$LOG"; then
    echo "[test_afunix] PASS: overall self-test PASS banner"
else
    echo "[test_afunix] FAIL: overall self-test PASS banner missing" >&2
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_afunix] FAIL"
    exit 1
fi

echo "[test_afunix] PASS -- AF_UNIX socketpair round-trips both" \
     "directions, bound-name STREAM listen/connect/accept exchange bytes," \
     "abstract namespace is isolated from pathnames, and" \
     "ECONNREFUSED/EADDRINUSE/SOCK_DGRAM-by-name all behave correctly"
