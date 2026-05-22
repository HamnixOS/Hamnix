#!/usr/bin/env bash
# scripts/test_u29_busybox.sh -- U29: run a real busybox on Hamnix.
#
# busybox is a fully-static x86_64 Linux ELF that bundles dozens of
# UNIX utilities. Getting the busybox multi-call banner to print from
# Hamnix's user mode is a meaningful end-to-end test of the Linux ABI
# surface: busybox's applet dispatch hits a much wider slice of
# syscalls than any of our hand-written u_* fixtures.
#
# FIXTURE (U42 re-point): this test used to drive the glibc-static
# `tests/u-binary/u_busybox`, an ET_EXEC linked at 0x400000. Commit
# 653d962 ("elf loader: refuse ET_EXEC overlay that collides with
# kernel image") made that binary dead on arrival -- its fixed LOAD
# range collides with Hamnix's identity-mapped kernel image, so the
# loader -ENOEXECs it. The test SKIP'd ever since. It now drives the
# musl static-PIE (ET_DYN) busybox fixture instead -- the same one
# test_u40_musl_busybox.sh exercises. ET_DYN loads at a kernel-chosen
# relocated base with no fixed-address overlay, so nothing collides.
# Same busybox 1.36.1, same applets -- just a leaner libc.
#
# The fixture (tests/u-binary/u_busybox_musl) is host-built by
# `make -C tests/u-binary/src/musl_busybox install`. If the fixture
# is missing this test SKIPs the same way U22 / U24 / U39 / U40 do --
# CI in environments without `musl-tools` keeps moving.

. "$(dirname "$0")/_build_lock.sh"
. "$(dirname "$0")/_ensure_ubin.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

UBIN=tests/u-binary/u_busybox_musl
# Build-on-missing: the fixture is gitignored (host-built). If absent,
# build it from tests/u-binary/src/musl_busybox; only SKIP on a real
# failure (e.g. a genuine missing musl-gcc, or no network to fetch the
# busybox upstream tarball).
ensure_ubin_or_skip test_u29_busybox u_busybox_musl musl_busybox

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf

echo "[test_u29_busybox] (1/4) Build userland"
bash scripts/build_user.sh
bash scripts/build_modules.sh

echo "[test_u29_busybox] (2/4) Swap /init + embed musl busybox"
# Stage the musl busybox as /bin/busybox. Busybox's main() dispatches
# to applets based on the basename of argv[0] -- with argv[0]=
# "busybox" it prints its banner, which is what this test greps for.
# build_initramfs.py picks up tests/u-binary/busybox and plants
# busybox-bytes at applet paths. The trap restores the default
# initramfs on exit.
cp tests/u-binary/u_busybox_musl tests/u-binary/busybox
HAMNIX_EMBED_UBIN=1 INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py

echo "[test_u29_busybox] (3/4) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF"

echo "[test_u29_busybox] (4/4) Boot QEMU + run busybox"
LOG=$(mktemp)
trap 'rm -f "$LOG" tests/u-binary/busybox; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null' EXIT

set +e
(
    sleep 3
    printf 'busybox\n'
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
