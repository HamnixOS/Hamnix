#!/usr/bin/env bash
# scripts/test_iso_qemu.sh - Boot build/hamnix.iso in QEMU (BIOS + UEFI).
#
# Two passes:
#   1. Legacy BIOS via qemu-system-x86_64 -cdrom (default SeaBIOS).
#   2. UEFI via -bios /usr/share/ovmf/OVMF.fd (only if OVMF.fd exists).
#
# Each pass runs for up to ISO_BOOT_TIMEOUT seconds (default 30). The
# kernel halts after printing its banner, so "qemu killed by timeout"
# is the expected success signal — same convention as run_x86_bare.sh.
#
# Success criterion: the captured serial output contains the banner.
# We grep for the literal string defined by BANNER_RE below.
#
# Env overrides:
#   HAMNIX_ISO         iso path                  (default: build/hamnix.iso)
#   ISO_BOOT_TIMEOUT   seconds per qemu run      (default: 30)
#   BANNER_RE          banner regex              (default: kernel banner —
#                                                  not just "Hamnix", which
#                                                  also appears in GRUB's
#                                                  own menu text)
#   SKIP_UEFI=1        skip the UEFI pass even if OVMF.fd exists

set -euo pipefail

PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

# shellcheck source=_build_lock.sh
source "$PROJ_ROOT/scripts/_build_lock.sh"

HAMNIX_ISO="${HAMNIX_ISO:-build/hamnix.iso}"
ISO_BOOT_TIMEOUT="${ISO_BOOT_TIMEOUT:-30}"
BANNER_RE="${BANNER_RE:-Hamnix kernel booting}"
OVMF_FD="/usr/share/ovmf/OVMF.fd"

if [ ! -f "$HAMNIX_ISO" ]; then
    echo "[test_iso_qemu] $HAMNIX_ISO not found — run scripts/build_iso.sh first." >&2
    exit 1
fi

run_qemu() {
    local label="$1"; shift
    local logfile
    logfile=$(mktemp --tmpdir hamnix-iso-${label}.XXXXXX.log)
    echo "[test_iso_qemu] === $label boot (timeout ${ISO_BOOT_TIMEOUT}s) ==="
    set +e
    timeout "${ISO_BOOT_TIMEOUT}s" qemu-system-x86_64 \
        "$@" \
        -m 256M \
        -nographic \
        -no-reboot \
        -monitor none \
        -serial stdio \
        2>&1 | tee "$logfile"
    local rc=${PIPESTATUS[0]}
    set -e
    # rc=124: timeout killed it. rc=0: clean exit. Both can be valid
    # depending on whether the kernel halts or QEMU exits via shutdown.
    if [ "$rc" -ne 0 ] && [ "$rc" -ne 124 ]; then
        echo "[test_iso_qemu] $label: qemu exited rc=$rc" >&2
        return "$rc"
    fi
    if grep -q -E "$BANNER_RE" "$logfile"; then
        echo "[test_iso_qemu] $label: banner detected (\"$BANNER_RE\")."
        rm -f "$logfile"
        return 0
    fi
    echo "[test_iso_qemu] $label: banner NOT detected in serial log ($logfile)." >&2
    return 1
}

# --- Pass 1: legacy BIOS ---
run_qemu "BIOS" -cdrom "$HAMNIX_ISO"
BIOS_OK=$?

UEFI_OK=skipped
if [ "${SKIP_UEFI:-0}" = "1" ]; then
    echo "[test_iso_qemu] UEFI: skipped (SKIP_UEFI=1)"
elif [ ! -f "$OVMF_FD" ]; then
    echo "[test_iso_qemu] UEFI: skipped ($OVMF_FD not found; apt install ovmf)"
else
    # OVMF needs a writable copy because UEFI variables get persisted.
    OVMF_RW=$(mktemp --tmpdir ovmf.XXXXXX.fd)
    cp "$OVMF_FD" "$OVMF_RW"
    run_qemu "UEFI" -bios "$OVMF_RW" -cdrom "$HAMNIX_ISO"
    UEFI_OK=$?
    rm -f "$OVMF_RW"
fi

echo
echo "[test_iso_qemu] Summary:"
echo "  BIOS: $([ "$BIOS_OK" -eq 0 ] && echo PASS || echo FAIL)"
echo "  UEFI: $UEFI_OK"

if [ "$BIOS_OK" -ne 0 ]; then
    exit 1
fi
if [ "$UEFI_OK" != "skipped" ] && [ "$UEFI_OK" -ne 0 ]; then
    exit 1
fi
echo "[test_iso_qemu] All boot paths passed."
