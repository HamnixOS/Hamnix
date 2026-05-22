#!/usr/bin/env bash
# scripts/test_mkpart.sh — M16.x partition-table WRITE side verification.
#
# Mints a freshly-zeroed AHCI disk image (no MBR signature, no
# partition entries) and boots the kernel against it. The
# partition module recognises "sd0 + no-signature" as the trigger
# for the mkpart smoke fixture (tests/test_mkpart.ad), which:
#
#   1. partition_mklabel_mbr(slot)        -> "[mkpart] mbr label OK"
#   2. partition_mkpart_mbr(slot, 0, ...) -> "[mkpart] partition 0 ..."
#   3. partition_mkpart_mbr(slot, 1, ...) -> "[mkpart] partition 1 ..."
#   4. partition_rescan(slot)             -> two "[partition] disk=sd0 ..."
#   5. blk_register_partitions invoked from the AHCI init path:
#          blk: registered 'sd0p1' capacity=30720 sectors
#          blk: registered 'sd0p2' capacity=32768 sectors
#
# The end-LBA in the `[mkpart]` line uses the as-passed exclusive
# convention (32768, 65536). The `[partition]` line emits inclusive
# last LBA (32767, 65535) — the read-side parser's convention.
#
# Why AHCI specifically? The kernel registers AHCI as "sd0", and
# the mkpart fixture is name-gated on "sd0\0" so it doesn't fire
# on vda/ram0/nvme0n1 — that keeps every other test in the matrix
# unaffected (zero regressions on test_partition.sh,
# test_partition_naming.sh, etc.). virtio-blk + brd register as
# "vda" / "ram0", so they always skip the fixture.

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf

echo "[test_mkpart] (1/4) Build userland + modules + initramfs"
if [ ! -f build/user/init.elf ]; then
    bash scripts/build_user.sh >/dev/null
    bash scripts/build_modules.sh >/dev/null
fi
INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null

echo "[test_mkpart] (2/4) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

echo "[test_mkpart] (3/4) Mint a 64 MiB blank SATA disk (no MBR sig)"
# Zero disk — no MBR signature, no partition entries. The fixture
# inside the kernel will lay down a valid empty MBR + two primaries
# from scratch and re-scan.
DISK=$(mktemp --suffix=.mkpart-ahci.img)
dd if=/dev/zero of="$DISK" bs=1M count=64 status=none

LOG=$(mktemp)
trap 'rm -f "$LOG" "$DISK"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null' EXIT

echo "[test_mkpart] (4/4) Boot QEMU on blank AHCI disk"
set +e
timeout 25s qemu-system-x86_64 \
    -kernel "$ELF" \
    -drive if=none,file="$DISK",format=raw,id=hd0 \
    -device ahci,id=ahci0 \
    -device ide-hd,drive=hd0,bus=ahci0.0 \
    -nographic -no-reboot -m 256M -monitor none -serial stdio \
    > "$LOG" 2>&1 < /dev/null
rc=$?
set -e

echo "[test_mkpart] --- captured (mkpart / partition / blk lines) ---"
grep -E '\[mkpart\]|\[partition\]|blk: registered' "$LOG" || true
echo "[test_mkpart] --- end ---"

fail=0

# Write-side markers from the fixture.
for needle in \
    "[mkpart] mbr label OK" \
    "[mkpart] partition 0 lba=2048..32768 type=0x83" \
    "[mkpart] partition 1 lba=32768..65536 type=0x83" \
    "[mkpart] PASS"
do
    if grep -F -q "$needle" "$LOG"; then
        echo "[test_mkpart] OK (write): '$needle'"
    else
        echo "[test_mkpart] MISS (write): '$needle'"
        fail=1
    fi
done

# Read-back markers — the same disk is parsed by parse_mbr after
# the writes and emits the [partition] lines with inclusive last-LBA.
for needle in \
    "[partition] disk=sd0 idx=0 lba=2048..32767 type=0x83" \
    "[partition] disk=sd0 idx=1 lba=32768..65535 type=0x83"
do
    if grep -F -q "$needle" "$LOG"; then
        echo "[test_mkpart] OK (rescan): '$needle'"
    else
        echo "[test_mkpart] MISS (rescan): '$needle'"
        fail=1
    fi
done

# Block-layer sibling registration. After the rescan populates
# partition_table[] for sd0, blk_register_partitions(bslot, "sd0")
# inside the AHCI init path mints sd0p1 + sd0p2. Capacity for
# sd0p1 = 32768 - 2048 = 30720 sectors.
for needle in \
    "blk: registered 'sd0p1' capacity=30720 sectors" \
    "blk: registered 'sd0p2' capacity=32768 sectors"
do
    if grep -F -q "$needle" "$LOG"; then
        echo "[test_mkpart] OK (register): '$needle'"
    else
        echo "[test_mkpart] MISS (register): '$needle'"
        fail=1
    fi
done

if [ "$fail" -ne 0 ]; then
    echo "[test_mkpart] FAIL (qemu rc=$rc)"
    echo "[test_mkpart] --- full log ---"
    cat "$LOG"
    exit 1
fi

echo "[test_mkpart] PASS"
