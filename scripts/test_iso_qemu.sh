#!/usr/bin/env bash
# scripts/test_iso_qemu.sh - DEPRECATED thin shim.
#
# Hamnix no longer ships a bootable ISO, NOR a baked GPT disk image. A
# real system is INSTALLED onto a disk by the installer; the boot
# acceptance gate is now scripts/test_installer_nvme_inram.sh, which boots
# the ESP-only installer medium under OVMF, installs a real GPT + ext4
# root + ESP onto a blank NVMe via the in-RAM installer, then proves the
# bytes landed — the genuine UEFI boot + install path.
#
# This script used to boot build/hamnix.iso in QEMU on BOTH a legacy
# BIOS (SeaBIOS -> GRUB -> multiboot1) pass and a UEFI (OVMF -cdrom)
# pass. All of that is gone:
#   * BIOS / legacy / SeaBIOS boot   — dropped; Hamnix is UEFI-only.
#   * the hybrid BIOS+UEFI ISO        — dropped; build_iso.sh is itself
#                                       now a shim.
#   * the baked GPT image hamnix.img  — retired; a real system is
#                                       installed onto a disk, never
#                                       shipped as a pre-baked root image.
#
# Rather than fail looking for a build/hamnix.iso (or build/hamnix.img)
# that no longer exists, this shim delegates to the real successor gate so
# any caller that expected test_iso_qemu.sh to "verify the bootable image"
# still gets a meaningful boot test — now of the installer/installed path.
#
# The developer `-kernel` QEMU smoke path (scripts/run_x86_bare.sh,
# scripts/_kernel_iso.sh) is a separate TEST harness and is unaffected.

set -euo pipefail

PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

cat >&2 <<'NOTICE'
[test_iso_qemu] DEPRECATED: the bootable ISO and the baked disk image
[test_iso_qemu]   have both been removed. A real system is installed onto
[test_iso_qemu]   a disk by the installer. Delegating to
[test_iso_qemu]   scripts/test_installer_nvme_inram.sh, which boots the
[test_iso_qemu]   installer medium under OVMF and installs to a real NVMe.
NOTICE

exec bash "$PROJ_ROOT/scripts/test_installer_nvme_inram.sh" "$@"
