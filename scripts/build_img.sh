#!/usr/bin/env bash
# scripts/build_img.sh - Build a REAL installed-system raw disk image for
# Hamnix: build/hamnix.img.
#
# This REPLACES the cpio-rooted hybrid ISO (scripts/build_iso.sh) with a
# GPT, UEFI-ONLY disk image that boots the way a shipped distro does:
#
#   GPT disk
#   ├── Partition 1: ESP (FAT)
#   │     \EFI\BOOT\BOOTX64.EFI   (the native PE/COFF stub, efi_stub.S)
#   │     \hamnix-kernel.elf      (the elf64 higher-half kernel)
#   └── Partition 2: ext4
#         .hamnix-roots           (sentinel: #sysroot -> sysroot/, #distro -> distro/)
#         sysroot/                (native Adder tools + libs + /init + etc)
#         distro/                 (minimal Debian: apt/dpkg/busybox closure)
#
# THE ONE-FILESYSTEM RULE (docs/rootfs_partition.md):
#   sysroot/, distro/, and future per-user home roots are SUBTREES of a
#   SINGLE ext4 filesystem. They share free space; they are NOT separate
#   partitions. On install the ext4 grows to fill the disk so every
#   subtree draws from one common pool.
#
# BOOT FLOW (no cpio in the final state):
#   1. UEFI firmware launches \EFI\BOOT\BOOTX64.EFI off the ESP.
#   2. The stub loads \hamnix-kernel.elf off the ESP, builds page tables,
#      and jumps into the kernel.
#   3. The kernel probes block devices (virtio-blk/AHCI/USB), scans GPT
#      partitions, and finds the ext4 partition by its 0xEF53 superblock
#      magic. mount_rootfs_partition() reads `.hamnix-roots` and posts a
#      named file server for each subtree (#sysroot, #distro).
#   4. The kernel binds `#sysroot` at `/` into the root Pgrp, then
#      ELF-loads `/init` off ext4 (sysroot/init) via the namespace.
#   5. /init execs `/bin/hamsh /etc/rc.boot`; both resolve off
#      sysroot/ through the inherited bind. hamsh-as-PID-1 runs the rc
#      and drops to an interactive shell.
#
# UEFI-ONLY: there is NO BIOS / GRUB / multiboot-rescue / El-Torito /
# hybrid-MBR path here. Legacy boot is dropped entirely.
#
# Required Debian packages: mtools binutils e2fsprogs parted
#   (mformat/mcopy, as/ld, mkfs.ext4, parted)
#
# Env overrides:
#   HAMNIX_IMG_OUT          output image           (default: build/hamnix.img)
#   HAMNIX_KERNEL           kernel ELF             (default: build/hamnix-kernel.elf)
#   HAMNIX_EFI_STUB         PE/COFF stub output    (default: build/hamnix-bootx64.efi)
#   HAMNIX_ROOTFS_IMG       ext4 partition image   (default: build/hamnix-rootfs.img)
#   HAMNIX_ROOTFS_SIZE_MB   shipped ext4 size MiB  (default: 512)

set -euo pipefail

PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

# Serialize with the rest of the build pipeline (shares the kernel ELF +
# fs/initramfs_blob.S with every test_*.sh).
# shellcheck source=_build_lock.sh
source "$PROJ_ROOT/scripts/_build_lock.sh"

HAMNIX_KERNEL="${HAMNIX_KERNEL:-build/hamnix-kernel.elf}"
HAMNIX_EFI_STUB="${HAMNIX_EFI_STUB:-build/hamnix-bootx64.efi}"
HAMNIX_IMG_OUT="${HAMNIX_IMG_OUT:-build/hamnix.img}"
HAMNIX_ROOTFS_IMG="${HAMNIX_ROOTFS_IMG:-build/hamnix-rootfs.img}"
# Ship ~0.5 GB of ext4; the first-boot resize hook grows it to fill the
# disk on a real install.
export HAMNIX_ROOTFS_SIZE_MB="${HAMNIX_ROOTFS_SIZE_MB:-512}"

# --- Host-tool sanity (clear message instead of a cryptic failure) ----
need_tool() {
    if ! command -v "$1" >/dev/null 2>&1; then
        echo "[build_img] ERROR: '$1' not found in PATH." >&2
        echo "[build_img]   apt-get install mtools binutils e2fsprogs parted" >&2
        exit 1
    fi
}
need_tool mformat
need_tool mcopy
need_tool mmd
need_tool as
need_tool ld
need_tool dd
need_tool file
# parted + mkfs.ext4 commonly live only in /sbin, which isn't on a
# non-root PATH. Resolve full paths explicitly.
PARTED="/sbin/parted"
if [ ! -x "$PARTED" ]; then
    PARTED="$(command -v parted || true)"
    if [ -z "$PARTED" ]; then
        echo "[build_img] ERROR: 'parted' not found in /sbin or PATH." >&2
        echo "[build_img]   apt-get install parted" >&2
        exit 1
    fi
fi
MKFS_EXT4="/sbin/mkfs.ext4"
if [ ! -x "$MKFS_EXT4" ]; then
    MKFS_EXT4="$(command -v mkfs.ext4 || true)"
    if [ -z "$MKFS_EXT4" ]; then
        echo "[build_img] ERROR: 'mkfs.ext4' not found in /sbin or PATH." >&2
        echo "[build_img]   apt-get install e2fsprogs" >&2
        exit 1
    fi
fi

# --- Build userland + modules + the ext4 rootfs partition -------------
#
# build_user.sh produces build/user/*.elf (the ~110 Adder tools + the
# /init shim) and build_modules.sh produces the framework .kos. The
# rootfs builder stages those into sysroot/ + distro/ on the ext4
# partition image.
echo "[build_img] Rebuilding userland + modules."
bash scripts/build_user.sh
bash scripts/build_modules.sh

# The kernel image still `.incbin`s fs/initramfs_blob.S (the cpio symbol
# initramfs_cpio_base is referenced at link time by fs/cpio.ad). Build a
# TRAILER-ONLY (empty) cpio: the kernel links, but the SHIPPED image
# carries NO embedded userland — the installed disk boots ENTIRELY off
# the ext4 root (kernel binds '#sysroot' / and ELF-loads /init off the
# partition; verified by scripts/test_img_uefi_boot.sh's
# HAMNIX_PARTITION_RC_SOURCED_OK assertion). This is the "no cpio in the
# live install path" end state. The `-kernel` developer/test path keeps
# its own full cpio via run_x86_bare.sh.
echo "[build_img] Building empty initramfs (kernel boots off ext4; cpio symbol kept for link)."
HAMNIX_CPIO_EMPTY=1 python3 scripts/build_initramfs.py

echo "[build_img] Building ext4 rootfs partition (~${HAMNIX_ROOTFS_SIZE_MB} MiB shipped)."
HAMNIX_ROOTFS_OUT="$HAMNIX_ROOTFS_IMG" python3 scripts/build_rootfs_img.py
if [ ! -f "$HAMNIX_ROOTFS_IMG" ]; then
    echo "[build_img] ERROR: build_rootfs_img.py did not produce $HAMNIX_ROOTFS_IMG" >&2
    exit 1
fi

# --- Compile the kernel ELF (atomic temp + mv) ------------------------
#
# `ld` writes its output file incrementally and is NOT atomic. Compile
# to a unique temp path, then rename into place so a reader never sees a
# half-written prefix and an interrupted run never leaves a stale partial
# at the final name.
echo "[build_img] Compiling kernel ELF."
rm -f "$HAMNIX_KERNEL"
KERNEL_TMP="${HAMNIX_KERNEL}.tmp.$$"
rm -f "$KERNEL_TMP" "${HAMNIX_KERNEL}".tmp.* 2>/dev/null || true
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$KERNEL_TMP"
if [ ! -f "$KERNEL_TMP" ]; then
    echo "[build_img] ERROR: compiler did not produce $KERNEL_TMP" >&2
    exit 1
fi
sync "$KERNEL_TMP" 2>/dev/null || sync
mv -f "$KERNEL_TMP" "$HAMNIX_KERNEL"
echo "[build_img] Kernel: $(file -b "$HAMNIX_KERNEL")"

# --- Build the native UEFI PE/COFF stub -------------------------------
#
# A standalone PE32+ EFI_APPLICATION assembled from efi_stub.S. PATH A:
# the stub loads \hamnix-kernel.elf off the ESP, builds page tables/GDT,
# and jumps to the kernel. (UEFI loads PE/COFF only; the stub has no
# multiboot constraint, so it's a true elf64 object before ld -m i386pep
# repackages it as PE32+.)
echo "[build_img] Building native UEFI stub: $HAMNIX_EFI_STUB"
EFI_STUB_SRC="arch/x86/boot/efi_stub.S"
if [ ! -f "$EFI_STUB_SRC" ]; then
    echo "[build_img] ERROR: $EFI_STUB_SRC missing." >&2
    exit 1
fi
EFI_STUB_TMP=$(mktemp -d)
trap 'rm -rf "$EFI_STUB_TMP"' EXIT
as --64 -o "$EFI_STUB_TMP/efi_stub.o" "$EFI_STUB_SRC"
#   --subsystem 10 = IMAGE_SUBSYSTEM_EFI_APPLICATION
#   -e efi_main    = PE entry symbol
#   --image-base 0 = UEFI relocates anywhere; keep in-image refs RVA-clean
ld -m i386pep --subsystem 10 -e efi_main --image-base 0 \
   --no-dynamic-linker -nostdlib \
   -o "$HAMNIX_EFI_STUB" "$EFI_STUB_TMP/efi_stub.o"
if ! file "$HAMNIX_EFI_STUB" | grep -q "PE32+ executable for EFI"; then
    echo "[build_img] ERROR: $HAMNIX_EFI_STUB is not a PE32+ EFI application." >&2
    file "$HAMNIX_EFI_STUB" >&2
    exit 1
fi
echo "[build_img] EFI stub: $(file -b "$HAMNIX_EFI_STUB")"

# --- Build the ESP (FAT) partition image ------------------------------
#
# Holds the EFI stub + the kernel ELF. FAT12 with explicit geometry —
# OVMF on Debian rejects FAT16/FAT32 ESPs ("Not Found" from BdsDxe), but
# loads a FAT12 ESP cleanly (verified empirically; see build_iso.sh).
ESP_IMG="$EFI_STUB_TMP/esp.img"
KERNEL_BYTES=$(stat -c%s "$HAMNIX_KERNEL")
# Size the ESP at kernel + stub + 8 MiB headroom, rounded up to MiB,
# floored at 32 MiB so a small kernel still leaves room to grow.
ESP_SIZE_MB=$(( (KERNEL_BYTES + (16 * 1024 * 1024)) / (1024 * 1024) ))
if [ "$ESP_SIZE_MB" -lt 32 ]; then ESP_SIZE_MB=32; fi
echo "[build_img] Building ${ESP_SIZE_MB} MiB FAT ESP (kernel=${KERNEL_BYTES} B)."
dd if=/dev/zero of="$ESP_IMG" bs=1M count="$ESP_SIZE_MB" status=none
# Geometry: -h 64 -s 32 → each track = 32*512 = 16 KiB; tracks = MiB*64.
# -c 32 (16 KiB clusters) keeps FAT12's 4084-cluster ceiling for sizes
# up to ~64 MiB.
mformat -i "$ESP_IMG" -h 64 -s 32 -c 32 \
        -t $(( ESP_SIZE_MB * 64 )) -v HAMNIX ::

# --- Boot-log persistence file (docs: kernel/printk/esp_log.ad) -------
#
# Preallocate a fixed-size LOG.TXT on the ESP *FIRST*, before any other
# file, so its data extent is the first contiguous run of clusters in the
# freshly-formatted volume (deterministic, never fragmented). The kernel
# locates this extent at boot and overwrites it in place via raw
# blk_write_sectors to persist the printk ring — so a bad real-hardware
# boot (NUC, no serial) leaves its log on the stick.
#
# Fill with NEWLINES (0x0A), not NULs. The kernel only overwrites the
# leading sectors it actually has log+marker content for (a flush on a
# flaky USB bus is expensive, so it does NOT rewrite the whole 256 KiB);
# whatever tail it leaves untouched is this build-time fill. Newlines keep
# the file clean, printable text from byte 0 to EOF — opening \LOG.TXT in
# any editor shows the real log, the "==== END OF HAMNIX LOG ====" marker,
# then blank lines, instead of the old sea of NUL "weird symbols".
#
# HAMNIX_ESP_LOG_SIZE MUST match ESP_LOG_BYTES in kernel/printk/
# esp_log.ad (default 262144 = 256 KiB = 512 sectors).
HAMNIX_ESP_LOG_SIZE="${HAMNIX_ESP_LOG_SIZE:-262144}"
ESP_LOG_SRC="$EFI_STUB_TMP/log.txt"
# `head -c N` reads exactly N zero bytes then closes; `tr` (the final
# pipeline stage) translates each NUL to a newline. Putting `tr` last
# avoids the SIGPIPE that would trip `set -o pipefail` if it were feeding
# a `dd count=...` that closed the pipe early.
head -c "$HAMNIX_ESP_LOG_SIZE" /dev/zero | tr '\0' '\n' > "$ESP_LOG_SRC"
mcopy -o -i "$ESP_IMG" "$ESP_LOG_SRC" "::/LOG.TXT"
echo "[build_img] Preallocated \\LOG.TXT (${HAMNIX_ESP_LOG_SIZE} B, newline-filled) for boot-log persistence."

mmd -i "$ESP_IMG" "::/EFI"
mmd -i "$ESP_IMG" "::/EFI/BOOT"
mcopy -o -i "$ESP_IMG" "$HAMNIX_EFI_STUB" "::/EFI/BOOT/BOOTX64.EFI"
mcopy -o -i "$ESP_IMG" "$HAMNIX_KERNEL"   "::/hamnix-kernel.elf"
echo "[build_img] ESP contents:"
mdir -i "$ESP_IMG" ::/          | sed 's/^/    /'
mdir -i "$ESP_IMG" ::/EFI/BOOT/ | sed 's/^/    /'

# --- Assemble the GPT disk image --------------------------------------
#
# Layout (1 MiB alignment throughout):
#   [ 1 MiB GPT primary + alignment gap ]
#   [ Partition 1: ESP   (esp flag, FAT)  ]
#   [ Partition 2: ext4  (Linux native)   ]
#   [ GPT backup at end ]
ALIGN_MB=1
ESP_START_MB=$ALIGN_MB
ROOTFS_BYTES=$(stat -c%s "$HAMNIX_ROOTFS_IMG")
ROOTFS_MB=$(( (ROOTFS_BYTES + (1024 * 1024) - 1) / (1024 * 1024) ))
ROOT_START_MB=$(( ESP_START_MB + ESP_SIZE_MB ))
ROOT_END_MB=$(( ROOT_START_MB + ROOTFS_MB ))
# Total = root end + 1 MiB for the GPT backup header.
TOTAL_MB=$(( ROOT_END_MB + ALIGN_MB ))

echo "[build_img] Disk layout: ESP ${ESP_START_MB}..${ROOT_START_MB} MiB, " \
     "ext4 ${ROOT_START_MB}..${ROOT_END_MB} MiB, total ${TOTAL_MB} MiB."

rm -f "$HAMNIX_IMG_OUT"
dd if=/dev/zero of="$HAMNIX_IMG_OUT" bs=1M count="$TOTAL_MB" status=none

# Create the GPT + two partitions with parted. UEFI-only: the ESP gets
# the `esp` flag (GPT type GUID C12A7328-... + the legacy boot flag);
# partition 2 is left as a plain Linux-filesystem-type partition.
"$PARTED" -s "$HAMNIX_IMG_OUT" mklabel gpt
"$PARTED" -s "$HAMNIX_IMG_OUT" \
    mkpart ESP fat32 "${ESP_START_MB}MiB" "${ROOT_START_MB}MiB"
"$PARTED" -s "$HAMNIX_IMG_OUT" set 1 esp on
"$PARTED" -s "$HAMNIX_IMG_OUT" \
    mkpart hamnix-rootfs ext4 "${ROOT_START_MB}MiB" "${ROOT_END_MB}MiB"

# dd the pre-built filesystem images into the partition byte offsets.
# conv=notrunc so we overwrite in place without truncating the GPT.
echo "[build_img] Writing ESP image into partition 1."
dd if="$ESP_IMG" of="$HAMNIX_IMG_OUT" bs=1M seek="$ESP_START_MB" \
   conv=notrunc status=none
echo "[build_img] Writing ext4 image into partition 2."
dd if="$HAMNIX_ROOTFS_IMG" of="$HAMNIX_IMG_OUT" bs=1M seek="$ROOT_START_MB" \
   conv=notrunc status=none

# --- Verify the assembled image ---------------------------------------
echo "[build_img] GPT partition table:"
"$PARTED" -s "$HAMNIX_IMG_OUT" unit s print 2>/dev/null | sed 's/^/    /'

# Confirm the ext4 superblock magic 0xEF53 lands at the partition's byte
# offset + 1024 (sanity that the dd seek math is right).
ROOT_START_BYTES=$(( ROOT_START_MB * 1024 * 1024 ))
EXT4_MAGIC=$(dd if="$HAMNIX_IMG_OUT" bs=1 \
                skip=$(( ROOT_START_BYTES + 1024 + 0x38 )) \
                count=2 status=none | od -An -tx1 | tr -d ' \n')
if [ "$EXT4_MAGIC" != "53ef" ]; then
    echo "[build_img] ERROR: ext4 magic 0xEF53 not found at partition 2 offset" \
         "(got 0x${EXT4_MAGIC})." >&2
    exit 1
fi
echo "[build_img]   ext4 magic 0xEF53 OK at partition 2 (byte ${ROOT_START_BYTES}+1024)."

IMG_BYTES=$(stat -c%s "$HAMNIX_IMG_OUT")
echo "[build_img] DONE: $HAMNIX_IMG_OUT"
echo "[build_img]   total image : ${IMG_BYTES} bytes ($(( IMG_BYTES / 1024 / 1024 )) MiB)"
echo "[build_img]   ESP part 1  : ${ESP_SIZE_MB} MiB (FAT: BOOTX64.EFI + hamnix-kernel.elf)"
echo "[build_img]   ext4 part 2 : ${ROOTFS_MB} MiB (sysroot/ + distro/ + .hamnix-roots)"
echo "[build_img] UEFI-only GPT disk image. Test with: bash scripts/test_img_uefi_boot.sh"
