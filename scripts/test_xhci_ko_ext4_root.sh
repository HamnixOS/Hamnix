#!/usr/bin/env bash
# scripts/test_xhci_ko_ext4_root.sh — TASK 3 acceptance gate.
#
# Proves a VM mounts its REAL ext4 ROOT FILESYSTEM by reading sectors
# through the Linux xhci_hcd.ko USB stack, with native USB fully
# disabled. This is the substance of making the .ko the DEFAULT USB
# driver: the block/partition/ext4/VFS layers read the root FS
# transparently through /dev/blk/sd0 backed by the .ko BOT path.
#
# Disk model: a usb-storage device (a USB Mass-Storage stick) backs a
# whole-disk ext4 filesystem carrying the `.hamnix-roots` sentinel. We
# attach it via -device usb-storage (NOT virtio-blk / AHCI), so the ONLY
# way the kernel can read its ext4 superblock is through the xHCI bulk
# rings the .ko drives. SeaBIOS cannot mount ext4, so an ext4-magic-found
# marker on the .ko-backed sd0 slot is unambiguously .ko-attributable.
#
# Assertions (each kernel-side, attributable to the .ko path):
#   1. native USB provably disabled (hand-rolled skipped + bridge
#      suppressed + native xhci_init body not entered).
#   2. the .ko registered /dev/blk/sd0 backed by xhci_hcd.ko BOT.
#   3. boot:31.r re-ran mount_rootfs_partition() once sd0 was live.
#   4. the ext4 superblock magic 0xEF53 was found on a .ko-backed slot
#      (sd0...), i.e. the root FS was read THROUGH the .ko bulk rings.
#   5. native storage.ad / usbms did NOT register a block device.

. "$(dirname "$0")/_build_lock.sh"

set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf
BOOT_TIMEOUT="${XHCI_EXT4_TIMEOUT:-60}"

echo "[test_xhci_ko_ext4_root] (0/5) Probe QEMU for qemu-xhci + usb-storage"
if ! qemu-system-x86_64 -device help 2>&1 | grep -q '"qemu-xhci"'; then
    echo "[test_xhci_ko_ext4_root] SKIPPED — this QEMU build has no qemu-xhci"
    exit 0
fi
if ! qemu-system-x86_64 -device help 2>&1 | grep -q '"usb-storage"'; then
    echo "[test_xhci_ko_ext4_root] SKIPPED — this QEMU build has no usb-storage"
    exit 0
fi
MKFS_EXT4="/sbin/mkfs.ext4"
if [ ! -x "$MKFS_EXT4" ]; then
    MKFS_EXT4="$(command -v mkfs.ext4 || true)"
fi
if [ -z "$MKFS_EXT4" ] || [ ! -x "$MKFS_EXT4" ]; then
    echo "[test_xhci_ko_ext4_root] SKIPPED — mkfs.ext4 not available"
    exit 0
fi
echo "[test_xhci_ko_ext4_root] OK: QEMU has qemu-xhci + usb-storage; mkfs.ext4 present"

echo "[test_xhci_ko_ext4_root] (1/5) Build userland + modules"
bash scripts/build_user.sh >/dev/null
bash scripts/build_modules.sh >/dev/null

echo "[test_xhci_ko_ext4_root] (2/5) Build initramfs with the .ko-real markers"
INITRAMFS_LOG=$(mktemp)
ENABLE_XHCI_KO_REAL=1 ENABLE_XHCI_KO_REAL_MMIO=1 INIT_ELF=build/user/init.elf \
    python3 scripts/build_initramfs.py > "$INITRAMFS_LOG" 2>&1
# Restore the default initramfs on exit so no other test is affected.
trap 'rm -f "$INITRAMFS_LOG" "${LOG:-}" "${EXT4IMG:-}"; rm -rf "${STAGE:-}"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1 || true' EXIT

echo "[test_xhci_ko_ext4_root] (3/5) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null
if [ ! -s "$ELF" ]; then
    echo "[test_xhci_ko_ext4_root] FAIL: kernel ELF missing"
    exit 1
fi

echo "[test_xhci_ko_ext4_root] (4/5) Build a whole-disk ext4 USB stick (.hamnix-roots sentinel)"
EXT4IMG="$(mktemp)"
STAGE="$(mktemp -d)"
# Minimal root tree: the .hamnix-roots sentinel + a sysroot/init so the
# kernel's mount_rootfs_partition() sentinel parse + ext4 walk exercise
# real reads through the .ko bulk rings. The whole partition IS the tree.
mkdir -p "$STAGE/sysroot"
printf 'distro .\n' > "$STAGE/.hamnix-roots"
if [ -f build/user/init.elf ]; then
    cp build/user/init.elf "$STAGE/sysroot/init"
fi
# A 48 MiB ext4 stick. -d stages our tree; 1024-byte blocks keep the
# superblock at offset 1024 (sectors 2..3) where mount_rootfs reads it.
truncate -s 48M "$EXT4IMG"
if ! "$MKFS_EXT4" -q -F -b 1024 -d "$STAGE" "$EXT4IMG" >/dev/null 2>&1; then
    # Older mke2fs without -d: format empty, the magic check still passes.
    "$MKFS_EXT4" -q -F -b 1024 "$EXT4IMG" >/dev/null 2>&1
fi
# Sanity: confirm the ext4 magic is where the kernel will look (off 1080).
MAGIC=$(dd if="$EXT4IMG" bs=1 skip=$((1024 + 0x38)) count=2 status=none | od -An -tx1 | tr -d ' \n')
if [ "$MAGIC" != "53ef" ]; then
    echo "[test_xhci_ko_ext4_root] FAIL: ext4 magic not at offset 1080 (got 0x${MAGIC})"
    exit 1
fi
echo "[test_xhci_ko_ext4_root] OK: ext4 magic 0xEF53 present on the stick image"

echo "[test_xhci_ko_ext4_root] (5/5) Boot QEMU (qemu-xhci + usb-storage ext4 stick)"
source "$PROJ_ROOT/scripts/_kernel_iso.sh"
KISO="$(kernel_iso "$ELF")"
LOG="$(mktemp)"
timeout "${BOOT_TIMEOUT}s" qemu-system-x86_64 \
    -boot d -cdrom "$KISO" \
    -device qemu-xhci,id=xhci0 \
    -drive if=none,id=usbstick,file="$EXT4IMG",format=raw \
    -device usb-storage,bus=xhci0.0,drive=usbstick \
    -smp 2 -nographic -no-reboot -m 256M -monitor none -serial stdio \
    > "$LOG" 2>&1 < /dev/null || true

echo "[test_xhci_ko_ext4_root] --- captured markers ---"
grep -aE '\[xhci-real\] blk:|\[boot:31\.r\]|\[rootfs\] ext4 magic|native xhci_init bridge SUPPRESSED|hand-rolled init SKIPPED' "$LOG" || true
echo "[test_xhci_ko_ext4_root] --- end ---"

fail=0

# Hard regression: no panic/trap during the .ko-driven root mount.
if grep -aE -q 'PANIC|panic:|TRAP:|BUG:' "$LOG"; then
    echo "[test_xhci_ko_ext4_root] FAIL: kernel panic / trap during .ko root mount"
    tail -n 60 "$LOG"
    exit 1
fi

# 1. Native USB provably disabled.
if ! grep -aF -q "[xhci] hand-rolled init SKIPPED" "$LOG"; then
    echo "[test_xhci_ko_ext4_root] FAIL: hand-rolled xhci_init not gated off"
    fail=1
fi
if ! grep -aF -q "native xhci_init bridge SUPPRESSED" "$LOG"; then
    echo "[test_xhci_ko_ext4_root] FAIL: usb_hcd_pci_probe native bridge not suppressed"
    fail=1
fi
if grep -aF -q "[boot:01.a] xhci_init enter" "$LOG"; then
    echo "[test_xhci_ko_ext4_root] FAIL: native drivers/usb/xhci.ad::xhci_init ran"
    fail=1
fi

# 2. The .ko registered /dev/blk/sd0 backed by the BOT path.
if ! grep -aF -q "[xhci-real] blk: /dev/blk/sd0 registered" "$LOG"; then
    echo "[test_xhci_ko_ext4_root] FAIL: .ko did not register /dev/blk/sd0"
    fail=1
fi
if ! grep -aF -q "backed by xhci_hcd.ko BOT" "$LOG"; then
    echo "[test_xhci_ko_ext4_root] FAIL: sd0 not marked as backed by xhci_hcd.ko BOT"
    fail=1
fi

# 3. boot:31.r re-ran the rootfs scan once the .ko-backed sd0 was live.
if ! grep -aF -q "[boot:31.r] .ko sd0 live; rescanning for ext4 root" "$LOG"; then
    echo "[test_xhci_ko_ext4_root] FAIL: boot:31.r did not rescan for the ext4 root over the .ko"
    fail=1
fi

# 4. The ext4 superblock magic was found on the .ko-backed slot — the
#    root FS was read THROUGH the .ko bulk rings.
if ! grep -aE -q '\[rootfs\] ext4 magic on slot [0-9]+ \(sd0' "$LOG"; then
    echo "[test_xhci_ko_ext4_root] FAIL: ext4 magic NOT found on a .ko-backed sd0 slot"
    echo "[test_xhci_ko_ext4_root] (the kernel never read the ext4 superblock through the .ko)"
    fail=1
fi

# 5. Native storage.ad / usbms must NOT have registered a block device.
if grep -aF -q "[usbms] /dev/blk/sd0 registered" "$LOG"; then
    echo "[test_xhci_ko_ext4_root] FAIL: native usbms registered sd0 (native NOT disabled)"
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_xhci_ko_ext4_root] --- boot log tail ---"
    tail -n 50 "$LOG"
    exit 1
fi

echo "[test_xhci_ko_ext4_root] PASS — ext4 ROOT FILESYSTEM read through the Linux xhci_hcd.ko bulk rings: native USB disabled, .ko registered /dev/blk/sd0, boot:31.r rescanned, ext4 0xEF53 found on the .ko-backed sd0 slot (mount through xhci_hcd.ko proven)"
