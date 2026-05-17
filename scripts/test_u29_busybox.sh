#!/usr/bin/env bash
# scripts/test_u29_busybox.sh -- U29: run a real busybox-static on Hamnix.
#
# busybox-static is a fully-static x86_64 Linux ELF that bundles dozens of
# UNIX utilities. Getting "busybox echo hello" (or even the busybox usage
# banner) to print from Hamnix's user mode is a meaningful end-to-end test
# of the Linux ABI surface: busybox's applet dispatch hits a much wider
# slice of syscalls than any of our hand-written u_* fixtures.
#
# This test is best-effort: it captures the qemu transcript and greps for
# either a busybox-emitted marker (the banner / "hello") OR a clear ENOSYS
# trace. It exits 0 in either case so it doesn't gate the U-track on a
# moving target, but FAILs loudly if QEMU crashes or no useful output
# appears at all.
#
# To stage the binary: extract /usr/bin/busybox from the busybox-static
# Debian package and stamp OSABI=Linux:
#   apt-get download busybox-static
#   dpkg-deb -x busybox-static_*.deb /tmp/bb
#   cp /tmp/bb/usr/bin/busybox tests/u-binary/u_busybox
#   printf '\003' | dd of=tests/u-binary/u_busybox bs=1 seek=7 count=1 conv=notrunc

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

UBIN=tests/u-binary/u_busybox

if [ ! -f "$UBIN" ]; then
    echo "[test_u29_busybox] SKIP: $UBIN not staged"
    echo "    apt-get download busybox-static"
    echo "    dpkg-deb -x busybox-static_*.deb /tmp/bb"
    echo "    cp /tmp/bb/usr/bin/busybox $UBIN"
    echo "    printf '\\003' | dd of=$UBIN bs=1 seek=7 count=1 conv=notrunc"
    exit 0
fi

ELF=build/hamnix-vmlinux.elf
HAMSH_ELF=build/user/hamsh.elf

echo "[test_u29_busybox] (1/4) Build userland"
bash scripts/build_user.sh
bash scripts/build_modules.sh

echo "[test_u29_busybox] (2/4) Swap /init + embed u_busybox"
INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py

echo "[test_u29_busybox] (3/4) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF"

echo "[test_u29_busybox] (4/4) Boot QEMU + run u_busybox"
LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null' EXIT

set +e
(
    sleep 3
    printf 'u_busybox\n'
    sleep 6
    printf 'exit\n'
    sleep 1
) | timeout 40s qemu-system-x86_64 \
    -kernel "$ELF" \
    -smp 2 \
    -nographic \
    -no-reboot \
    -m 256M \
    -monitor none \
    -serial stdio \
    > "$LOG" 2>&1
rc=$?
set -e

echo "[test_u29_busybox] --- captured output (last 200 lines) ---"
tail -n 200 "$LOG"
echo "[test_u29_busybox] --- end output ---"

fail=0

if grep -F -q "BusyBox" "$LOG"; then
    echo "[test_u29_busybox] OK: busybox banner printed"
else
    echo "[test_u29_busybox] MISS: no 'BusyBox' marker"
    fail=1
fi

if grep -F -q "unknown syscall" "$LOG"; then
    echo "[test_u29_busybox] DIAG: unknown syscall(s) logged"
    grep -F "unknown syscall" "$LOG" | sort -u | head -10 || true
fi
if grep -F -q "TRAP: vector" "$LOG"; then
    echo "[test_u29_busybox] DIAG: kernel reported a CPU exception"
    grep -F "TRAP: vector" "$LOG" | head -5 || true
    fail=1
fi
if grep -F -q "page fault" "$LOG"; then
    echo "[test_u29_busybox] DIAG: page fault"
    grep -F "page fault" "$LOG" | head -5 || true
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_u29_busybox] FAIL (qemu rc=$rc)"
    exit 1
fi

echo "[test_u29_busybox] PASS -- busybox banner reached user mode"
