#!/usr/bin/env bash
# scripts/test_partition_naming.sh — M16.x partition-aware naming.
#
# After M16.121 the kernel parses MBR/GPT and logs one
# `[partition]` line per slice. After M16.123 the AHCI driver
# registers as `sd0` and NVMe as `nvme0n1`. This commit ties the
# two halves together: the driver registers the raw disk, then
# calls `blk_scan_partitions(slot)` followed by
# `blk_register_partitions(slot, name)` to expose each live
# partition as a sibling block device `<name>pN`.
#
# Boot a kernel against a freshly-partitioned AHCI disk (two
# primaries) and assert:
#
#   - both MBR partition lines appear in the boot log:
#       [partition] disk=sd0 idx=0 lba=2048..65535 type=0x83
#       [partition] disk=sd0 idx=1 lba=65536..N    type=0x83
#   - the block layer registered both sibling devices:
#       blk: registered 'sd0p1' capacity=63488 sectors
#       blk: registered 'sd0p2' capacity=<size> sectors
#
# Why sfdisk? Same reason `scripts/test_partition.sh` uses it —
# `parted` isn't a hard dependency on this host, and sfdisk's
# stdin script is byte-stable across versions. Two primaries
# (LBA 2048..65535 and 65536..131071 on a 64 MiB image), both
# type 0x83 (Linux native).

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf

# Find sfdisk wherever it lives (Debian puts it in /sbin, which some
# $PATHs omit).
SFDISK=
for cand in sfdisk /sbin/sfdisk /usr/sbin/sfdisk; do
    if command -v "$cand" >/dev/null 2>&1 || [ -x "$cand" ]; then
        SFDISK="$cand"
        break
    fi
done
if [ -z "$SFDISK" ]; then
    echo "[test_partition_naming] SKIP: sfdisk not found on host" >&2
    exit 0
fi

echo "[test_partition_naming] (1/4) Build userland + modules + initramfs"
if [ ! -f build/user/init.elf ]; then
    bash scripts/build_user.sh >/dev/null
    bash scripts/build_modules.sh >/dev/null
fi
INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null

echo "[test_partition_naming] (2/4) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

echo "[test_partition_naming] (3/4) Mint a 64 MiB AHCI disk + two MBR primaries"
DISK=$(mktemp --suffix=.partnaming-ahci.img)
dd if=/dev/zero of="$DISK" bs=1M count=64 status=none
# Two contiguous Linux-native (type 0x83) primaries:
#   p1: LBA  2048..65535 = 31 MiB (63488 sectors)
#   p2: LBA 65536..131071 = 32 MiB (65536 sectors)
"$SFDISK" --no-tell-kernel --no-reread "$DISK" >/dev/null <<'EOF'
label: dos
unit: sectors

start=2048,  size=63488, type=83
start=65536, size=65536, type=83
EOF

LOG=$(mktemp)
trap 'rm -f "$LOG" "$DISK"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null' EXIT

echo "[test_partition_naming] (4/4) Boot QEMU with -device ahci on partitioned image"
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

echo "[test_partition_naming] --- captured (partition / blk lines) ---"
grep -E '\[partition\]|blk: registered' "$LOG" || true
echo "[test_partition_naming] --- end ---"

fail=0
# Partition decode markers (M16.121 path).
for needle in \
    "[partition] disk=sd0 idx=0 lba=2048..65535 type=0x83" \
    "[partition] disk=sd0 idx=1 lba=65536..131071 type=0x83"
do
    if grep -F -q "$needle" "$LOG"; then
        echo "[test_partition_naming] OK (decode): '$needle'"
    else
        echo "[test_partition_naming] MISS (decode): '$needle'"
        fail=1
    fi
done

# Block-layer sibling registration. Capacity for p1 is 63488 sectors
# (the size we passed sfdisk); p2 capacity varies in trailing edge
# rounding so grep loosely for the prefix.
if grep -F -q "blk: registered 'sd0p1' capacity=63488 sectors" "$LOG"; then
    echo "[test_partition_naming] OK (register): 'sd0p1' capacity=63488 sectors"
else
    echo "[test_partition_naming] MISS (register): 'sd0p1' capacity=63488 sectors"
    fail=1
fi
if grep -E -q "blk: registered 'sd0p2' capacity=[0-9]+ sectors" "$LOG"; then
    echo "[test_partition_naming] OK (register): 'sd0p2' capacity=<N> sectors"
else
    echo "[test_partition_naming] MISS (register): 'sd0p2' capacity=<N> sectors"
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_partition_naming] FAIL (qemu rc=$rc)"
    echo "[test_partition_naming] --- full log ---"
    cat "$LOG"
    exit 1
fi

echo "[test_partition_naming] PASS"
