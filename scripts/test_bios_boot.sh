#!/usr/bin/env bash
# scripts/test_bios_boot.sh - RETIRED.
#
# Hamnix is UEFI-only. Legacy BIOS / SeaBIOS boot was dropped together
# with the hybrid ISO (see scripts/build_iso.sh's deprecation shim).
# There is no longer a BIOS boot path to exercise, so this test SKIPs
# cleanly. The UEFI boot is covered by scripts/test_img_uefi_boot.sh,
# which boots the installed-system GPT image build/hamnix.img under
# OVMF as a DISK and asserts the kernel boots its shell off the ext4
# root.
#
# Pass marker:  [test_bios_boot] SKIP
#
# Kept as a stub (rather than deleted) so any cron template or runner
# that greps for this script's marker still sees a clean, explained
# SKIP instead of a "file not found".

set -euo pipefail

echo "[test_bios_boot] SKIP: BIOS boot retired — Hamnix is UEFI-only."
echo "[test_bios_boot]   The bootable artifact is the GPT disk image"
echo "[test_bios_boot]   build/hamnix.img (UEFI). Verify it with:"
echo "[test_bios_boot]     bash scripts/test_img_uefi_boot.sh"
exit 0
