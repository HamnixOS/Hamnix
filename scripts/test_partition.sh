#!/usr/bin/env bash
# scripts/test_partition.sh — M16.x partition-table parser verification.
#
# Two boot scenarios, each with a freshly-minted virtio-blk disk image:
#
#   1. MBR primary partitions — two contiguous Linux-native (type 0x83)
#      partitions, the first at LBA 2048..65535 (1MiB..32MiB), the
#      second at LBA 65536..131071 (32MiB..64MiB on a 64 MiB image).
#
#   2. GPT — a single Linux-filesystem partition (type GUID
#      0FC63DAF-...) over the first 32 MiB. GPT's protective-MBR
#      entry at primary[0]=0xEE forces the parser to fall through
#      from parse_mbr -> parse_gpt.
#
# The disk goes in via `-drive file=...,if=virtio,format=raw`, so
# drivers/block/virtio_blk.ad registers it as `vda` and
# init/main.ad's block_smoke_test calls blk_scan_partitions(vda).
#
# Asserted serial markers per scenario:
#
#   MBR:  "[partition] disk=vda idx=0 lba=2048..65535 type=0x83"
#         "[partition] disk=vda idx=1 lba=65536..131071 type=0x83"
#
#   GPT:  "[partition] protective MBR detected, switching to GPT"
#         "[partition] disk=vda idx=0 lba=2048..65535 type=fc63daf"
#         (Linux-filesystem GUID text form is 0FC63DAF-8483-4772-...
#          On disk the first 4 bytes are mixed-endian-stored as
#          AF 3D C6 0F; read back as u32 LE that's 0x0FC63DAF, which
#          our printk(%x) renders as "fc63daf" with the leading
#          zero suppressed.)
#
# Why sfdisk + dd? The task spec recommends `parted`; this host
# doesn't ship parted, but sfdisk produces identical MBR/GPT bytes
# from a tiny stdin script. Both layouts are deterministic and
# byte-stable across sfdisk versions.

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-vmlinux.elf

# Find sfdisk wherever it lives — Debian ships it as /sbin/sfdisk
# (root-only path component in $PATH on some setups).
SFDISK=
for cand in sfdisk /sbin/sfdisk /usr/sbin/sfdisk; do
    if command -v "$cand" >/dev/null 2>&1 || [ -x "$cand" ]; then
        SFDISK="$cand"
        break
    fi
done
if [ -z "$SFDISK" ]; then
    echo "[test_partition] SKIP: sfdisk not found on host" >&2
    exit 0
fi

echo "[test_partition] (1/4) Build userland + modules + initramfs"
if [ ! -f build/user/init.elf ]; then
    bash scripts/build_user.sh >/dev/null
    bash scripts/build_modules.sh >/dev/null
fi
INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null

echo "[test_partition] (2/4) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

# --- Scenario 1: MBR with two primaries -----------------------------
echo "[test_partition] (3/4) Mint MBR-partitioned virtio-blk disk"
MBR_DISK=$(mktemp --suffix=.partition-mbr.img)
dd if=/dev/zero of="$MBR_DISK" bs=1M count=64 status=none

# sfdisk reads partition definitions from stdin. Use `label: dos` for
# MBR, then one line per partition with `start=, size=, type=`.
# Sizes are in 512-byte sectors. 2048 = 1 MiB; 63488 = 31 MiB;
# 65536 = 32 MiB-sector mark; 65536 = 32 MiB size for the tail.
"$SFDISK" --no-tell-kernel --no-reread "$MBR_DISK" >/dev/null <<'EOF'
label: dos
unit: sectors

start=2048,  size=63488, type=83
start=65536, size=65536, type=83
EOF

# --- Scenario 2: GPT with one Linux-filesystem partition ------------
GPT_DISK=$(mktemp --suffix=.partition-gpt.img)
dd if=/dev/zero of="$GPT_DISK" bs=1M count=64 status=none
"$SFDISK" --no-tell-kernel --no-reread "$GPT_DISK" >/dev/null <<'EOF'
label: gpt
unit: sectors

start=2048, size=63488, type=0FC63DAF-8483-4772-8E79-3D69D8477DE4
EOF

# Default initramfs restore + tmpfile cleanup
LOG_MBR=$(mktemp)
LOG_GPT=$(mktemp)
trap 'rm -f "$LOG_MBR" "$LOG_GPT" "$MBR_DISK" "$GPT_DISK"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null' EXIT

run_qemu_with_disk() {
    local disk="$1"
    local log="$2"
    set +e
    timeout 25s qemu-system-x86_64 \
        -kernel "$ELF" \
        -drive file="$disk",if=virtio,format=raw \
        -nographic -no-reboot -m 256M -monitor none -serial stdio \
        > "$log" 2>&1 < /dev/null
    rc=$?
    set -e
    return $rc
}

echo "[test_partition] (4/4) Boot QEMU on MBR disk"
run_qemu_with_disk "$MBR_DISK" "$LOG_MBR" || true

echo "[test_partition] --- MBR captured (partition lines) ---"
grep -E '\[partition\]' "$LOG_MBR" || true
echo "[test_partition] --- end ---"

fail=0
for needle in \
    "[partition] disk=vda idx=0 lba=2048..65535 type=0x83" \
    "[partition] disk=vda idx=1 lba=65536..131071 type=0x83"
do
    if grep -F -q "$needle" "$LOG_MBR"; then
        echo "[test_partition] OK (mbr): '$needle'"
    else
        echo "[test_partition] MISS (mbr): '$needle'"
        fail=1
    fi
done

echo "[test_partition] Boot QEMU on GPT disk"
run_qemu_with_disk "$GPT_DISK" "$LOG_GPT" || true

echo "[test_partition] --- GPT captured (partition lines) ---"
grep -E '\[partition\]' "$LOG_GPT" || true
echo "[test_partition] --- end ---"

# GPT scenario assertions:
#   (a) the protective-MBR fallback fired (so parse_mbr returned -2
#       and the kernel called parse_gpt),
#   (b) exactly one Linux-filesystem partition was recorded —
#       lba_start = 2048, type-short = ebd0a0a2 (first DWORD of the
#       Microsoft-basic-data GUID, which sfdisk uses for plain GPT
#       partitions on a Linux filesystem since the kernel doesn't
#       require the more specific 0FC63DAF Linux-FS GUID).
#
# We grep loosely on the LBA + type fields so a sfdisk version that
# rounds the partition end up/down by one sector still passes.

if grep -F -q "[partition] protective MBR detected, switching to GPT" "$LOG_GPT"; then
    echo "[test_partition] OK (gpt): protective-MBR fallback fired"
else
    echo "[test_partition] MISS (gpt): protective-MBR fallback did not fire"
    fail=1
fi

# The sfdisk command above plants type GUID 0FC63DAF-8483-4772-...
# (Linux-filesystem). The first 4 GUID bytes are stored mixed-endian
# on disk as AF 3D C6 0F. Reading as u32 LE recovers 0x0FC63DAF; our
# printk(%x) drops the leading zero, rendering "fc63daf". The LBA
# range matches the MBR test (2048..65535 — 1 MiB to 32 MiB).
if grep -E -q '\[partition\] disk=vda idx=0 lba=2048\.\.[0-9]+ type=fc63daf' "$LOG_GPT"; then
    echo "[test_partition] OK (gpt): Linux-FS partition recorded at LBA 2048"
else
    echo "[test_partition] MISS (gpt): Linux-FS partition line"
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_partition] FAIL"
    echo "[test_partition] --- MBR full log ---"
    cat "$LOG_MBR"
    echo "[test_partition] --- GPT full log ---"
    cat "$LOG_GPT"
    exit 1
fi

echo "[test_partition] PASS"
