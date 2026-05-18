#!/usr/bin/env bash
# scripts/test_bios_boot.sh - Boot build/hamnix.iso under legacy BIOS (SeaBIOS)
#                            and assert the Hamnix kernel banner.
#
# This is the "hybrid ISO, BIOS half" half of the M16.70 priority — the
# inverse of scripts/test_uefi_boot.sh. Both scripts intentionally have
# the SAME pass-marker format ([test_<label>_boot] PASS) so the cron
# template can grep either output line.
#
# Path under test:
#   QEMU SeaBIOS  ->  MBR (boot_hybrid.img)  ->  El Torito i386-pc
#   ->  GRUB legacy core image  ->  /boot/grub/grub.cfg
#   ->  multiboot1 of /boot/hamnix.elf  ->  arch/x86/boot/header.S _start
#   ->  long-mode handoff  ->  start_kernel()
#
# We do NOT pass `-bios` here — QEMU's default is SeaBIOS, which is the
# legacy-BIOS code path. That's exactly what we want to exercise.
#
# Pass marker:    [test_bios_boot] PASS
# Fail marker:    [test_bios_boot] FAIL
#
# Env overrides:
#   HAMNIX_ISO         iso path                 (default: build/hamnix.iso)
#   BIOS_BOOT_TIMEOUT  seconds for the run       (default: 30)
#   BANNER_RE          banner regex             (default: kernel banner)

set -euo pipefail

PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

# shellcheck source=_build_lock.sh
source "$PROJ_ROOT/scripts/_build_lock.sh"

HAMNIX_ISO="${HAMNIX_ISO:-build/hamnix.iso}"
BIOS_BOOT_TIMEOUT="${BIOS_BOOT_TIMEOUT:-30}"
BANNER_RE="${BANNER_RE:-Hamnix kernel booting}"

# Build the ISO on demand. CI typically runs build_iso.sh once and then
# reruns the boot tests independently, but a fresh checkout shouldn't
# require the caller to know about the dependency.
if [ ! -f "$HAMNIX_ISO" ]; then
    echo "[test_bios_boot] $HAMNIX_ISO not found — running scripts/build_iso.sh."
    bash "$PROJ_ROOT/scripts/build_iso.sh"
fi
if [ ! -f "$HAMNIX_ISO" ]; then
    echo "[test_bios_boot] FAIL: $HAMNIX_ISO still missing after build_iso.sh." >&2
    exit 1
fi

LOGFILE=$(mktemp --tmpdir hamnix-bios-boot.XXXXXX.log)
cleanup() { rm -f "$LOGFILE"; }
trap cleanup EXIT

echo "[test_bios_boot] === BIOS boot via SeaBIOS (timeout ${BIOS_BOOT_TIMEOUT}s, banner=\"$BANNER_RE\") ==="
set +e
timeout "${BIOS_BOOT_TIMEOUT}s" qemu-system-x86_64 \
    -cdrom "$HAMNIX_ISO" \
    -m 256M \
    -nographic \
    -no-reboot \
    -monitor none \
    -serial stdio \
    2>&1 | tee "$LOGFILE"
rc=${PIPESTATUS[0]}
set -e

# rc=124 means timeout killed it (expected — kernel keeps running). rc=0
# is a clean shutdown. Anything else is a real QEMU failure.
if [ "$rc" -ne 0 ] && [ "$rc" -ne 124 ]; then
    echo "[test_bios_boot] FAIL: qemu exited rc=$rc" >&2
    echo "[test_bios_boot] FAIL"
    exit 1
fi

if ! grep -a -q -E "$BANNER_RE" "$LOGFILE"; then
    echo "[test_bios_boot] FAIL: kernel banner (\"$BANNER_RE\") not detected." >&2
    echo "[test_bios_boot] FAIL"
    exit 1
fi

echo "[test_bios_boot] kernel banner detected (\"$BANNER_RE\")."
echo "[test_bios_boot] PASS"
