#!/usr/bin/env bash
# scripts/test_nvme_write.sh — verify the M16.118 NVMe I/O WRITE path
# by writing a known pattern to LBA 1 of namespace 1, reading it back
# via the existing READ path, and checking byte-for-byte equality.
#
# Check happens inside the kernel (drivers/nvme/nvme.ad's
# _nvme_write_smoke_test). We just grep the serial log for:
#
#   "[nvme] write LBA=1 nblocks=1 OK"
#   "[nvme] readback matches pattern"
#
# Hand-built tmpfile (dd zero, 1 MiB) with planted 0x55 0xAA at bytes
# 510..511 so the existing READ smoke test of LBA 0 still passes.
# Write hits LBA 1 to leave the MBR signature alone.

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-vmlinux.elf

echo "[test_nvme_write] (1/4) Rebuild initramfs"
if [ ! -f build/user/init.elf ]; then
    bash scripts/build_user.sh >/dev/null
    bash scripts/build_modules.sh >/dev/null
fi
INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null

echo "[test_nvme_write] (2/4) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

echo "[test_nvme_write] (3/4) Mint a 1 MiB NVMe namespace with valid MBR sig"
DISK=$(mktemp --suffix=.nvme-write-disk)
dd if=/dev/zero of="$DISK" bs=1M count=1 status=none
printf '\x55\xaa' | dd of="$DISK" bs=1 seek=510 conv=notrunc status=none

LOG=$(mktemp)
trap 'rm -f "$LOG" "$DISK"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null' EXIT

echo "[test_nvme_write] (4/4) Boot QEMU with -device nvme"
set +e
timeout 20s qemu-system-x86_64 \
    -kernel "$ELF" \
    -drive if=none,file="$DISK",format=raw,id=nvme0 \
    -device nvme,drive=nvme0,serial=hamnix1234 \
    -nographic -no-reboot -m 256M -monitor none -serial stdio \
    > "$LOG" 2>&1 < /dev/null
rc=$?
set -e

echo "[test_nvme_write] --- captured (nvme lines) ---"
grep -E '\[nvme\]' "$LOG" || true
echo "[test_nvme_write] --- end ---"

fail=0
for needle in \
    "[nvme] controller ready" \
    "[nvme] MBR signature OK" \
    "[nvme] write LBA=1 nblocks=1 OK" \
    "[nvme] readback matches pattern"
do
    if grep -F -q "$needle" "$LOG"; then
        echo "[test_nvme_write] OK: '$needle'"
    else
        echo "[test_nvme_write] MISS: '$needle'"
        fail=1
    fi
done

if grep -F -q "[nvme] readback MISMATCH" "$LOG"; then
    echo "[test_nvme_write] readback MISMATCH banner present — FAIL"
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_nvme_write] FAIL (qemu rc=$rc)"
    echo "[test_nvme_write] --- full log ---"
    cat "$LOG"
    exit 1
fi

echo "[test_nvme_write] PASS"
