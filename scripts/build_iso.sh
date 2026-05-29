#!/usr/bin/env bash
# scripts/build_iso.sh - DEPRECATED thin shim.
#
# Hamnix no longer ships a hybrid BIOS+UEFI ISO. The user-facing,
# installable artifact is now a UEFI-only GPT raw disk image,
# build/hamnix.img, produced by scripts/build_img.sh and verified by
# scripts/test_img_uefi_boot.sh.
#
# What was removed and why:
#   * BIOS / legacy / SeaBIOS boot              — UEFI-only end state.
#   * GRUB (grub-pc-bin / grub-efi / grub.cfg)  — the native PE/COFF
#       stub is the first Hamnix code that runs; no GRUB middleman.
#   * grub-mkrescue / xorriso / El Torito        — no CD-ROM image.
#   * hybrid MBR / --protective-msdos-label      — pure GPT.
#   * multiboot1-rescue ISO re-master dance      — the kernel ELF is
#       loaded off the ESP by the stub, not chainloaded by GRUB.
#
# The installed system boots ENTIRELY off its ext4 root: the kernel
# binds '#sysroot' / and ELF-loads /init off the partition (no embedded
# cpio userland in the shipped image). See:
#   scripts/build_img.sh            — the GPT/UEFI image builder
#   scripts/test_img_uefi_boot.sh   — the OVMF acceptance gate
#   docs/rootfs_partition.md        — the named-root ext4 layout
#
# The `-kernel` developer/test path is unaffected: run_x86_bare.sh and
# scripts/_kernel_iso.sh still build their own throwaway BIOS GRUB ISO
# for QEMU `-kernel`/`-cdrom` smoke boots; that is a TEST harness, not
# the shipped artifact, and keeps its own full cpio.
#
# This shim delegates to build_img.sh so any caller that expected
# build_iso.sh to "produce the bootable Hamnix image" still gets one —
# now build/hamnix.img instead of build/hamnix.iso.

set -euo pipefail

PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

cat >&2 <<'NOTICE'
[build_iso] DEPRECATED: the hybrid BIOS+UEFI ISO has been removed.
[build_iso]   Hamnix is now UEFI-only. Building the GPT raw disk image
[build_iso]   build/hamnix.img via scripts/build_img.sh instead.
[build_iso]   Test it with: bash scripts/test_img_uefi_boot.sh
NOTICE

exec bash "$PROJ_ROOT/scripts/build_img.sh" "$@"
