#!/usr/bin/env bash
# scripts/test_bios_boot.sh - RETIRED.
#
# Hamnix is UEFI-only. Legacy BIOS / SeaBIOS boot was dropped together
# with the hybrid ISO (see scripts/build_iso.sh's deprecation shim).
# There is no longer a BIOS boot path to exercise, so this test SKIPs
# cleanly. The UEFI boot is now covered by booting the INSTALLED system —
# the golden ext4-on-NVMe disk produced by the real installer
# (scripts/build_installed_nvme.sh + scripts/_installed_boot.sh) — since
# the baked GPT image build/hamnix.img was retired.
#
# Pass marker:  [test_bios_boot] SKIP
#
# Kept as a stub (rather than deleted) so any cron template or runner
# that greps for this script's marker still sees a clean, explained
# SKIP instead of a "file not found".

set -euo pipefail

echo "[test_bios_boot] SKIP: BIOS boot retired — Hamnix is UEFI-only."
echo "[test_bios_boot]   The bootable artifact is the installed ext4-on-NVMe"
echo "[test_bios_boot]   system (the real installer path). Verify the UEFI"
echo "[test_bios_boot]   boot with:  bash scripts/test_installer_nvme_inram.sh"
exit 0
