#!/usr/bin/env bash
# scripts/test_nvme_prp.sh — V4.2 NVMe PRP-list verification.
#
# Boots the kernel against an emulated NVMe drive and asserts that the
# cross-page-boundary I/O smoke test inside tests/test_nvme_prp.ad
# passes. The fixture issues a 512-byte WRITE+READ pair where the host
# buffer DELIBERATELY straddles a 4 KiB page boundary (intra-page
# offset 0xF10, so 240 bytes in page 0 and 272 bytes in page 1).
#
# Pre-V4.2 the driver only filled PRP1 in the SQE; the 272 bytes that
# should have landed in page 1 were silently dropped while the SQE
# still completed "successfully". The marker:
#
#   "[nvme_prp] cross-page readback matches"
#
# only appears when PRP1 + PRP2 are both populated correctly per
# NVMe spec §4.3 — i.e. when the V4.2 fix is in place.
#
# This is the test that closes out V4.2 and makes
# drivers/block/partition.ad's GPT bounce-buffer workaround
# unnecessary; the orchestrator will drop the bounce in a follow-up.

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf

echo "[test_nvme_prp] (1/4) Rebuild initramfs"
if [ ! -f build/user/init.elf ]; then
    bash scripts/build_user.sh >/dev/null
    bash scripts/build_modules.sh >/dev/null
fi
ENABLE_NVME_SELFTEST=1 INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null

echo "[test_nvme_prp] (2/4) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

echo "[test_nvme_prp] (3/4) Mint a 1 MiB NVMe namespace with valid MBR sig"
# 1 MiB tmpfile with the MBR signature planted so the existing LBA-0
# read smoke test still passes. The PRP fixture writes LBA 2, well
# clear of LBA 0 (MBR sig) and LBA 1 (existing write smoke target).
DISK=$(mktemp --suffix=.nvme-prp-disk)
dd if=/dev/zero of="$DISK" bs=1M count=1 status=none
printf '\x55\xaa' | dd of="$DISK" bs=1 seek=510 conv=notrunc status=none

LOG=$(mktemp)
trap 'rm -f "$LOG" "$DISK"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null' EXIT

echo "[test_nvme_prp] (4/4) Boot QEMU with -device nvme"
set +e
timeout 25s qemu-system-x86_64 \
    -kernel "$ELF" \
    -drive if=none,file="$DISK",format=raw,id=nvme0 \
    -device nvme,drive=nvme0,serial=hamnixprp1 \
    -nographic -no-reboot -m 256M -monitor none -serial stdio \
    > "$LOG" 2>&1 < /dev/null
rc=$?
set -e

echo "[test_nvme_prp] --- captured (nvme / nvme_prp lines) ---"
grep -E '\[nvme\]|\[nvme_prp\]' "$LOG" || true
echo "[test_nvme_prp] --- end ---"

fail=0
for needle in \
    "[nvme] controller ready" \
    "[nvme] PRP-list pool ready (64 pages)" \
    "[nvme_prp] smoke begin" \
    "[nvme_prp] cross-page write @ offset 0xF10 OK" \
    "[nvme_prp] cross-page readback matches" \
    "[nvme_prp] PASS"
do
    if grep -F -q "$needle" "$LOG"; then
        echo "[test_nvme_prp] OK: '$needle'"
    else
        echo "[test_nvme_prp] MISS: '$needle'"
        fail=1
    fi
done

if grep -F -q "[nvme_prp] MISMATCH" "$LOG"; then
    echo "[test_nvme_prp] MISMATCH banner present — FAIL"
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_nvme_prp] FAIL (qemu rc=$rc)"
    echo "[test_nvme_prp] --- full log ---"
    cat "$LOG"
    exit 1
fi

echo "[test_nvme_prp] PASS"
