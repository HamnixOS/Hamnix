#!/usr/bin/env bash
# scripts/test_gpt_mkpart.sh — M16.x GPT partition-table WRITE side
# verification. Counterpart to scripts/test_mkpart.sh, which covers
# the MBR write path.
#
# Mints a freshly-zeroed 32 MiB NVMe disk (no MBR signature) and boots
# the kernel against it. The partition module recognises "nvme0n1 +
# no-signature" as the GPT mkpart smoke trigger
# (tests/test_gpt_mkpart.ad), which:
#
#   1. gpt_init(slot, 65536)                  -> "[gpt] init OK ..."
#   2. gpt_mkpart(slot, 0, ESP)               -> "[gpt] mkpart idx=0 ..."
#   3. gpt_mkpart(slot, 1, Linux)             -> "[gpt] mkpart idx=1 ..."
#   4. type-GUID byte-order round-trip check  -> "[gpt_mkpart] type GUID ..."
#   5. protective-MBR layout check            -> "[gpt_mkpart] protective MBR OK ..."
#   6. primary <-> backup header consistency  -> "[gpt_mkpart] primary + backup ..."
#   7. partition_rescan picks up both entries -> "[partition] disk=nvme0n1 ..."
#
# The end-LBA in the [gpt] mkpart line uses the inclusive convention
# the GPT spec mandates (start..end inclusive). The [partition] line
# uses the same inclusive convention because that's how parse_gpt
# stores entries in the read-side partition_table.
#
# Why NVMe specifically? The kernel registers NVMe as "nvme0n1", and
# the GPT-mkpart fixture is name-gated on "nvme0n1\0" so it doesn't
# fire on vda/ram0/sd0/sd0pN. That keeps every other test in the
# matrix unaffected — in particular the MBR mkpart fixture (which
# fires on "sd0") and the read-side partition parser tests (vda).

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf

echo "[test_gpt_mkpart] (1/4) Build userland + modules + initramfs"
if [ ! -f build/user/init.elf ]; then
    bash scripts/build_user.sh >/dev/null
    bash scripts/build_modules.sh >/dev/null
fi
INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null

echo "[test_gpt_mkpart] (2/4) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

echo "[test_gpt_mkpart] (3/4) Mint a 32 MiB blank NVMe disk (no MBR sig)"
# Zero disk — no MBR signature, no partition entries. The fixture
# inside the kernel will lay down a fresh GPT (protective MBR + both
# header copies + both partition-array copies) and two GPT entries.
DISK=$(mktemp --suffix=.gpt-mkpart-nvme.img)
dd if=/dev/zero of="$DISK" bs=1M count=32 status=none

LOG=$(mktemp)
trap 'rm -f "$LOG" "$DISK"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null' EXIT

echo "[test_gpt_mkpart] (4/4) Boot QEMU on blank NVMe disk"
set +e
timeout 25s qemu-system-x86_64 \
    -kernel "$ELF" \
    -drive if=none,file="$DISK",format=raw,id=nvme0 \
    -device nvme,drive=nvme0,serial=hamnixgpt1 \
    -nographic -no-reboot -m 256M -monitor none -serial stdio \
    > "$LOG" 2>&1 < /dev/null
rc=$?
set -e

echo "[test_gpt_mkpart] --- captured (gpt / partition lines) ---"
grep -E '\[gpt\]|\[gpt_mkpart\]|\[partition\]' "$LOG" || true
echo "[test_gpt_mkpart] --- end ---"

fail=0

# Write-side markers from the fixture body.
for needle in \
    "[gpt_mkpart] smoke begin (nvme0n1, fresh disk)" \
    "[gpt] init OK (total=65536 last=65535)" \
    "[gpt] mkpart idx=0 lba=2048..6143" \
    "[gpt] mkpart idx=1 lba=6144..65500" \
    "[gpt_mkpart] type GUID bytes round-trip OK" \
    "[gpt_mkpart] protective MBR OK (0x55AA + entry[0]=0xEE)" \
    "[gpt_mkpart] primary + backup GPT headers consistent" \
    "[gpt_mkpart] PASS"
do
    if grep -F -q "$needle" "$LOG"; then
        echo "[test_gpt_mkpart] OK (write): '$needle'"
    else
        echo "[test_gpt_mkpart] MISS (write): '$needle'"
        fail=1
    fi
done

# Read-back markers — partition_rescan parses the GPT layout we just
# wrote and emits one [partition] line per recorded entry.
#
# Type-short is the first 4 bytes of the type GUID, read as a uint32
# LE. For the ESP (text "C12A7328-...") the on-disk bytes 0..3 are
# 28 73 2A C1, which as u32 LE is 0xC12A7328; printk(%x) renders it
# as "c12a7328" (no leading-zero suppression — the top nibble is C).
#
# For the Linux FS (text "0FC63DAF-...") bytes 0..3 are AF 3D C6 0F,
# u32 LE 0x0FC63DAF, printk(%x) renders as "fc63daf" (leading zero
# dropped — matches the existing test_partition.sh assertion).
for needle in \
    "[partition] protective MBR detected, switching to GPT" \
    "[partition] disk=nvme0n1 idx=0 lba=2048..6143 type=c12a7328" \
    "[partition] disk=nvme0n1 idx=1 lba=6144..65500 type=fc63daf"
do
    if grep -F -q "$needle" "$LOG"; then
        echo "[test_gpt_mkpart] OK (rescan): '$needle'"
    else
        echo "[test_gpt_mkpart] MISS (rescan): '$needle'"
        fail=1
    fi
done

if [ "$fail" -ne 0 ]; then
    echo "[test_gpt_mkpart] FAIL (qemu rc=$rc)"
    echo "[test_gpt_mkpart] --- full log ---"
    cat "$LOG"
    exit 1
fi

echo "[test_gpt_mkpart] PASS"
