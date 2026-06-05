#!/usr/bin/env bash
# scripts/build_iso.sh - DEPRECATED thin shim.
#
# Hamnix no longer ships a hybrid BIOS+UEFI ISO, NOR a baked GPT disk
# image. A real system is INSTALLED onto a disk by the installer; the
# user-facing artifact is the ESP-only installer medium
# build/hamnix-installer.img, produced by scripts/build_installer_img.sh
# and verified by scripts/test_installer_nvme_inram.sh.
#
# What was removed and why:
#   * BIOS / legacy / SeaBIOS boot              — UEFI-only end state.
#   * GRUB (grub-pc-bin / grub-efi / grub.cfg)  — the native PE/COFF
#       stub is the first Hamnix code that runs; no GRUB middleman.
#   * grub-mkrescue / xorriso / El Torito        — no CD-ROM image.
#   * hybrid MBR / --protective-msdos-label      — pure GPT.
#   * multiboot1-rescue ISO re-master dance      — the kernel ELF is
#       loaded off the ESP by the stub, not chainloaded by GRUB.
#   * the baked GPT image build/hamnix.img       — retired; a real system
#       is installed onto a disk, never shipped as a pre-baked root image.
#
# The installed system boots ENTIRELY off its ext4 root: the kernel
# binds '#sysroot' / and ELF-loads /init off the partition (no embedded
# cpio userland in the shipped image). See:
#   scripts/build_installer_img.sh        — the ESP-only installer builder
#   scripts/test_installer_nvme_inram.sh  — the OVMF install acceptance gate
#   docs/rootfs_partition.md              — the named-root ext4 layout
#
# The `-kernel` developer/test path is unaffected: run_x86_bare.sh and
# scripts/_kernel_iso.sh still build their own throwaway BIOS GRUB ISO
# for QEMU `-kernel`/`-cdrom` smoke boots; that is a TEST harness, not
# the shipped artifact, and keeps its own full cpio.
#
# This shim delegates to build_installer_img.sh so any caller that
# expected build_iso.sh to "produce the bootable Hamnix image" still gets
# one — now build/hamnix-installer.img.

set -euo pipefail

PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

cat >&2 <<'NOTICE'
[build_iso] DEPRECATED: the hybrid BIOS+UEFI ISO and the baked disk image
[build_iso]   have both been removed. A real system is installed onto a
[build_iso]   disk by the installer. Building the ESP-only installer medium
[build_iso]   build/hamnix-installer.img via build_installer_img.sh instead.
[build_iso]   Test it with: bash scripts/test_installer_nvme_inram.sh
NOTICE

exec bash "$PROJ_ROOT/scripts/build_installer_img.sh" "$@"
