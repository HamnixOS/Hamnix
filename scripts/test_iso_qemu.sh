#!/usr/bin/env bash
# scripts/test_iso_qemu.sh - DEPRECATED thin shim.
#
# Hamnix no longer ships a bootable ISO. The user-facing, installable
# artifact is the UEFI-only GPT raw disk image build/hamnix.img
# (scripts/build_img.sh), and the boot acceptance gate for it is
# scripts/test_img_uefi_boot.sh (boots the .img under OVMF as a disk
# and asserts the kernel banner, a live REPL, and that commands resolve
# off the ext4 root).
#
# This script used to boot build/hamnix.iso in QEMU on BOTH a legacy
# BIOS (SeaBIOS -> GRUB -> multiboot1) pass and a UEFI (OVMF -cdrom)
# pass. All of that is gone:
#   * BIOS / legacy / SeaBIOS boot   — dropped; Hamnix is UEFI-only.
#   * the hybrid BIOS+UEFI ISO        — dropped; build_iso.sh is itself
#                                       now a shim that builds the .img.
#   * the `cpio: registered N files`  — the shipped image carries an
#       deep marker                     empty trailer-only cpio and boots
#                                       entirely off ext4, so that marker
#                                       no longer appears on the live path.
#
# Rather than fail looking for a build/hamnix.iso that build_iso.sh no
# longer produces, this shim delegates to the real successor gate so any
# caller that expected test_iso_qemu.sh to "verify the bootable image"
# still gets a meaningful boot test — now of build/hamnix.img.
#
# The developer `-kernel` QEMU smoke path (scripts/run_x86_bare.sh,
# scripts/_kernel_iso.sh) is a separate TEST harness and is unaffected.

set -euo pipefail

PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

cat >&2 <<'NOTICE'
[test_iso_qemu] DEPRECATED: the bootable ISO has been removed.
[test_iso_qemu]   Hamnix is now UEFI-only and ships build/hamnix.img.
[test_iso_qemu]   Delegating to scripts/test_img_uefi_boot.sh, which
[test_iso_qemu]   boots the GPT disk image under OVMF.
NOTICE

exec bash "$PROJ_ROOT/scripts/test_img_uefi_boot.sh" "$@"
