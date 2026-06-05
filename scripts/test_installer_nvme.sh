#!/usr/bin/env bash
# scripts/test_installer_nvme.sh — self-hosted UEFI NVMe install, end-to-end.
#
# THIS TEST NOW DELEGATES TO scripts/test_installer_nvme_inram.sh.
#
# WHY. The original four-step installer ended its payload copy with
#   dd_blk /dev/blk/vdap2 /dev/blk/nvme0n1p2
# — a RUNTIME read of the install MEDIA's own ext4 partition. On the real
# Intel NUC target the install medium is a USB stick whose native
# USB/xHCI driver is broken, so that runtime media read is exactly the
# failure the in-RAM installer model exists to avoid: it defeats the whole
# "firmware loads everything into RAM; the installer only WRITES to NVMe"
# design.
#
# The fix (etc/install_nvme.hamsh rewrite + the in-RAM-squashfs streamer in
# drivers/block/loop.ad + scripts/build_installer_img.sh) makes the install
# medium an ESP-ONLY GPT image with NOTHING for the installer to read, and
# streams BOTH payloads (the NVMe ESP image + the ext4 root) out of a
# squashfs the FIRMWARE loaded into RAM inside the kernel cpio. There is no
# longer a media-read code path for this test to exercise — install_nvme.hamsh
# is a single shared script and now ONLY does the in-RAM flow.
#
# So this name (the "installer NVMe" regression gate) now runs the in-RAM
# test, which is the correct, current install flow. It is REAL end-to-end
# verification with bytes-on-disk proof (protective MBR 0x55AA + GPT
# "EFI PART" + ext4 0xEF53 read back off the NVMe qcow2 on the host) and a
# Stage-C boot of the installed NVMe ALONE to a shell with zero
# 'command not found' — identical rigor to the original, minus the removed
# media-read step.
#
# Env overrides are forwarded unchanged (BOOT_TIMEOUT, NVME_SIZE, OVMF_FD,
# HAMNIX_SKIP_BUILD, KEEP_LOGS, INSTALL_WAIT). It SKIPs cleanly (exit 0)
# when /dev/kvm, OVMF, or mksquashfs are absent.

set -uo pipefail

PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo "[test_installer_nvme] media-read install flow retired; delegating to the"
echo "[test_installer_nvme] in-RAM-squashfs installer test (the current flow)."
exec bash "$PROJ_ROOT/scripts/test_installer_nvme_inram.sh" "$@"
