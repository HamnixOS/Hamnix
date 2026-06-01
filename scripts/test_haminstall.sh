#!/usr/bin/env bash
# scripts/test_haminstall.sh — #172 on-target installer acceptance gate.
#
# Proves user/haminstall.ad performs a full native install from a
# RUNNING Hamnix system onto a blank disk, and that the kernel-level
# live-root safety guard refuses to clobber the disk we're booted from.
#
# Topology (three virtio disks):
#   vda = an ext4 "root" stick carrying the .hamnix-roots sentinel.
#         The kernel auto-mounts it as the live root FS, so
#         /dev/blk/rootdev reads back "vda" — this is the disk the
#         installer must REFUSE to touch.
#   vdb = a BLANK target disk. haminstall lays down GPT + ESP + ext4
#         root on it. We read this image back on the host afterwards.
#   vdc = a small FAT image used as the ESP source for the dd copy
#         (FAT has no per-file kernel writer; the ESP is a raw copy).
#
# Drive sequence (over hamsh stdin):
#   1. write a tiny rootfs manifest at /tmp/m + a source file, so the
#      manifest-driven copy actually creates a file on the new root.
#   2. haminstall vdb --esp-src vdc --manifest /tmp/m   (the install)
#   3. haminstall vda                                   (must REFUSE:
#      vda is the live root disk)
#
# Post-boot READ-BACK assertions on the vdb raw image (host-side):
#   * protective MBR signature 0x55AA at byte 0x1FE.
#   * GPT signature "EFI PART" at LBA 1 (byte 0x200).
#   * ext4 superblock magic 0xEF53 at the root partition's byte
#     offset + 1024  (the new root really got an ext4 FS).
#   * the ESP partition's first sector carries the FAT boot signature
#     0x55AA (the ESP source was copied in).
#
# In-log assertions (kernel + installer markers):
#   * "[haminstall] install complete on /dev/blk/vdb"
#   * "[haminstall] live root disk is /dev/blk/vda"
#   * "[haminstall] REFUSING: target IS the live root disk"  (guard)
#   * "[devblk] gpt_init"/"gpt_mkpart"/"mkfs_ext4" (kernel formatters)
#
# Boots via the ISO shim on PATH (raw `qemu -kernel` of a 64-bit ELF
# fails on this host; _kernel_iso.sh wraps the ELF in a GRUB ISO).

. "$(dirname "$0")/_build_lock.sh"

set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf
BOOT_TIMEOUT="${HAMINSTALL_TIMEOUT:-90}"

MKFS_EXT4="/sbin/mkfs.ext4"
if [ ! -x "$MKFS_EXT4" ]; then
    MKFS_EXT4="$(command -v mkfs.ext4 || true)"
fi
if [ -z "$MKFS_EXT4" ] || [ ! -x "$MKFS_EXT4" ]; then
    echo "[test_haminstall] SKIPPED — mkfs.ext4 not available"
    exit 0
fi
MFORMAT="$(command -v mformat || true)"
if [ -z "$MFORMAT" ]; then
    echo "[test_haminstall] SKIPPED — mformat (mtools) not available"
    exit 0
fi

echo "[test_haminstall] (1/6) Build userland + modules"
bash scripts/build_user.sh >/dev/null
bash scripts/build_modules.sh >/dev/null
if [ ! -s build/user/haminstall.elf ]; then
    echo "[test_haminstall] FAIL: build/user/haminstall.elf missing"
    exit 1
fi

echo "[test_haminstall] (2/6) Build initramfs"
INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null
trap 'INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1 || true; rm -f "${LOG:-}" "${ROOTIMG:-}" "${TGTIMG:-}" "${ESPIMG:-}"; rm -rf "${STAGE:-}"' EXIT

echo "[test_haminstall] (3/6) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null
if [ ! -s "$ELF" ]; then
    echo "[test_haminstall] FAIL: kernel ELF missing"
    exit 1
fi

echo "[test_haminstall] (4/6) Mint disks: vda(ext4 root) vdb(blank) vdc(FAT ESP src)"
ROOTIMG="$(mktemp --suffix=.haminstall-root.img)"
TGTIMG="$(mktemp --suffix=.haminstall-tgt.img)"
ESPIMG="$(mktemp --suffix=.haminstall-esp.img)"
STAGE="$(mktemp -d)"

# vda: a whole-disk ext4 root with the .hamnix-roots sentinel so the
# kernel mounts it as the live root (=> /dev/blk/rootdev == "vda").
mkdir -p "$STAGE/sysroot"
printf 'distro .\n' > "$STAGE/.hamnix-roots"
if [ -f build/user/init.elf ]; then
    cp build/user/init.elf "$STAGE/sysroot/init"
fi
truncate -s 64M "$ROOTIMG"
if ! "$MKFS_EXT4" -q -F -b 1024 -d "$STAGE" "$ROOTIMG" >/dev/null 2>&1; then
    "$MKFS_EXT4" -q -F -b 1024 "$ROOTIMG" >/dev/null 2>&1
fi
ROOTMAGIC=$(dd if="$ROOTIMG" bs=1 skip=$((1024 + 0x38)) count=2 status=none | od -An -tx1 | tr -d ' \n')
if [ "$ROOTMAGIC" != "53ef" ]; then
    echo "[test_haminstall] FAIL: source root ext4 magic not present (got 0x${ROOTMAGIC})"
    exit 1
fi

# vdb: a blank 96 MiB target (zeroed — no GPT, no MBR signature).
dd if=/dev/zero of="$TGTIMG" bs=1M count=96 status=none

# vdc: a 16 MiB FAT image standing in for the ISO ESP. Give it the
# canonical \EFI\BOOT layout so a copied ESP is recognisably bootable.
dd if=/dev/zero of="$ESPIMG" bs=1M count=16 status=none
"$MFORMAT" -i "$ESPIMG" -h 64 -s 32 -c 32 -t $(( 16 * 64 )) -v HAMNIXESP ::
mmd -i "$ESPIMG" "::/EFI" 2>/dev/null || true
mmd -i "$ESPIMG" "::/EFI/BOOT" 2>/dev/null || true
# A small placeholder BOOTX64.EFI so the copied ESP carries the boot file.
head -c 4096 /dev/zero > "$STAGE/BOOTX64.EFI"
mcopy -o -i "$ESPIMG" "$STAGE/BOOTX64.EFI" "::/EFI/BOOT/BOOTX64.EFI" 2>/dev/null || true

echo "[test_haminstall] (5/6) Boot QEMU + drive haminstall over hamsh stdin"
source "$PROJ_ROOT/scripts/_kernel_iso.sh"
KISO="$(kernel_iso "$ELF")"
LOG="$(mktemp)"

set +e
(
    # Wait for the boot rc to finish and drop to interactive hamsh.
    sleep 8
    # Stage a tiny rootfs manifest + a source file. The manifest copies
    # one real file onto the new root so install_rootfs_from_manifest
    # exercises the per-file ext4 write path (target dir 'etc' created).
    printf 'echo hamnix-haminstall-test > /tmp/src.txt\n'
    sleep 1
    printf 'echo "etc/marker.txt /tmp/src.txt" > /tmp/m\n'
    sleep 1
    # The install: GPT + mkfs + ESP copy (from vdc) + rootfs (manifest).
    printf 'haminstall vdb --esp-src vdc --manifest /tmp/m\n'
    sleep 25
    printf 'echo HAMINSTALL_PRIMARY_DONE\n'
    sleep 2
    # The guard: targeting the live root disk (vda) must be REFUSED.
    printf 'haminstall vda\n'
    sleep 4
    printf 'echo HAMINSTALL_GUARD_DONE\n'
    sleep 2
    printf 'exit\n'
    sleep 1
) | timeout "${BOOT_TIMEOUT}s" qemu-system-x86_64 \
    -boot d -cdrom "$KISO" \
    -drive if=virtio,file="$ROOTIMG",format=raw \
    -drive if=virtio,file="$TGTIMG",format=raw \
    -drive if=virtio,file="$ESPIMG",format=raw \
    -smp 2 -nographic -no-reboot -m 384M -monitor none -serial stdio \
    > "$LOG" 2>&1
RC=$?
set -e
echo "[test_haminstall] QEMU rc=$RC (124 = timeout-killed is acceptable)"

echo "[test_haminstall] --- captured installer/kernel markers ---"
grep -aE '\[haminstall\]|\[gpt\] (init|mkpart)|mkfs_ext4:|dd_blk: OK|live root disk|REFUSING' "$LOG" || true
echo "[test_haminstall] --- end ---"

fail=0

# Hard regression: no panic/trap during the install.
if grep -aE -q 'PANIC|panic:|TRAP:|BUG:' "$LOG"; then
    echo "[test_haminstall] FAIL: kernel panic / trap during install"
    tail -n 60 "$LOG"
    exit 1
fi

# --- in-log assertions ----------------------------------------------
check_log() {
    local re="$1"; local label="$2"
    if grep -aE -q "$re" "$LOG"; then
        echo "[test_haminstall]   OK : $label"
    else
        echo "[test_haminstall]   MISS: $label" >&2
        fail=1
    fi
}
check_log '\[haminstall\] Hamnix on-target installer'   "installer banner"
check_log '\[haminstall\] live root disk is /dev/blk/vda' "rootdev guard read vda"
# Kernel-side formatter markers (partition.ad / ext4 wrapper) — proof
# the install drove the in-kernel GPT + mkfs path, not just userland.
check_log '\[gpt\] init OK'                              "kernel gpt_init ran"
check_log '\[gpt\] mkpart idx=0'                         "kernel ESP mkpart ran"
check_log '\[gpt\] mkpart idx=1'                         "kernel root mkpart ran"
check_log 'mkfs_ext4: /dev/blk/vdbp2 OK'                 "ext4 mkfs on root partition"
check_log '\[haminstall\] install complete on /dev/blk/vdb' "install complete on vdb"
# The safety guard: a second run targeting the live root MUST refuse.
check_log '\[haminstall\] REFUSING: target IS the live root disk' "live-root refusal (guard)"

# --- host-side read-back of the installed vdb image -----------------
echo "[test_haminstall] (6/6) Read-back assertions on the installed target image"

# Protective MBR signature.
MBR_SIG=$(od -An -N2 -tx1 -j 0x1FE "$TGTIMG" | tr -d ' \n')
if [ "$MBR_SIG" = "55aa" ]; then
    echo "[test_haminstall]   OK : protective MBR 0x55AA present on vdb"
else
    echo "[test_haminstall]   MISS: protective MBR 0x55AA absent on vdb (got 0x$MBR_SIG)" >&2
    fail=1
fi

# GPT signature at LBA 1.
GPT_SIG=$(od -An -N8 -c -j 0x200 "$TGTIMG" | tr -d ' \n')
if echo "$GPT_SIG" | grep -q "EFIPART"; then
    echo "[test_haminstall]   OK : GPT 'EFI PART' signature present at LBA 1 on vdb"
else
    echo "[test_haminstall]   MISS: GPT 'EFI PART' absent at LBA 1 on vdb (got '$GPT_SIG')" >&2
    fail=1
fi

# ext4 magic at the root partition. hamnix_partition places the ESP at
# LBA 2048 spanning <esp_mb> MiB; the root partition starts right after.
# Default ESP = 32 MiB => root starts at LBA 2048 + 32*1024*1024/512 =
# 2048 + 65536 = 67584. ext4 superblock magic 0xEF53 lives at the
# partition byte offset + 1024 + 0x38.
ROOT_LBA=$(( 2048 + 32 * 1024 * 1024 / 512 ))
ROOT_OFF=$(( ROOT_LBA * 512 ))
EXT4_MAGIC=$(dd if="$TGTIMG" bs=1 skip=$(( ROOT_OFF + 1024 + 0x38 )) count=2 status=none | od -An -tx1 | tr -d ' \n')
if [ "$EXT4_MAGIC" = "53ef" ]; then
    echo "[test_haminstall]   OK : ext4 magic 0xEF53 on vdb root partition (LBA $ROOT_LBA)"
else
    echo "[test_haminstall]   MISS: ext4 magic 0xEF53 absent on vdb root (LBA $ROOT_LBA, got 0x$EXT4_MAGIC)" >&2
    fail=1
fi

# ESP boot signature: the FAT boot sector (copied from vdc) ends in
# 0x55AA. ESP starts at LBA 2048 => byte 2048*512 = 1048576; signature
# at +0x1FE.
ESP_OFF=$(( 2048 * 512 ))
ESP_SIG=$(od -An -N2 -tx1 -j $(( ESP_OFF + 0x1FE )) "$TGTIMG" | tr -d ' \n')
if [ "$ESP_SIG" = "55aa" ]; then
    echo "[test_haminstall]   OK : ESP FAT boot signature 0x55AA on vdb p1 (copied in)"
else
    echo "[test_haminstall]   MISS: ESP FAT boot signature 0x55AA absent on vdb p1 (got 0x$ESP_SIG)" >&2
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_haminstall] --- boot log tail ---"
    tail -n 70 "$LOG"
    echo "[test_haminstall] FAIL"
    exit 1
fi

echo "[test_haminstall] PASS — haminstall laid down a GPT + FAT ESP (boot files) + ext4 root on the blank disk, and REFUSED to touch the live root disk (kernel /dev/blk/rootdev guard)."
