#!/usr/bin/env bash
# scripts/test_iso_qemu.sh - Boot build/hamnix.iso in QEMU (BIOS + UEFI).
#
# Two passes:
#   1. Legacy BIOS via qemu-system-x86_64 -cdrom (default SeaBIOS).
#      Banner = the regular kernel banner; we go all the way through
#      GRUB → multiboot1 → start_kernel().
#   2. UEFI via -bios /usr/share/ovmf/OVMF.fd (only if OVMF.fd exists).
#      Banner = the native PE/COFF stub's serial marker. The stub is
#      the FIRST piece of Hamnix that UEFI executes (no GRUB-EFI in the
#      path) and currently halts after printing the marker — full
#      kernel handoff from the EFI stub is a follow-up commit. The new
#      marker proves the direct-UEFI boot path works.
#
# Each pass runs for up to ISO_BOOT_TIMEOUT seconds (default 30). The
# kernel (BIOS) or the EFI stub (UEFI) both halt the CPU after printing
# their banner, so "qemu killed by timeout" is the expected success
# signal — same convention as run_x86_bare.sh.
#
# Env overrides:
#   HAMNIX_ISO         iso path                  (default: build/hamnix.iso)
#   ISO_BOOT_TIMEOUT   seconds per qemu run      (default: 30)
#   BANNER_RE          BIOS-pass banner regex    (default: kernel banner —
#                                                  not just "Hamnix", which
#                                                  also appears in GRUB's
#                                                  own menu text)
#   UEFI_BANNER_RE     UEFI-pass banner regex    (default: EFI stub marker —
#                                                  proves the native PE
#                                                  entry path ran. Distinct
#                                                  from BANNER_RE because
#                                                  the EFI stub currently
#                                                  halts before start_kernel)
#   SKIP_UEFI=1        skip the UEFI pass even if OVMF.fd exists

set -euo pipefail

PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

# shellcheck source=_build_lock.sh
source "$PROJ_ROOT/scripts/_build_lock.sh"

HAMNIX_ISO="${HAMNIX_ISO:-build/hamnix.iso}"
ISO_BOOT_TIMEOUT="${ISO_BOOT_TIMEOUT:-30}"
BANNER_RE="${BANNER_RE:-Hamnix kernel booting}"
UEFI_BANNER_RE="${UEFI_BANNER_RE:-\[hamnix\] EFI entry reached}"
OVMF_FD="/usr/share/ovmf/OVMF.fd"

if [ ! -f "$HAMNIX_ISO" ]; then
    echo "[test_iso_qemu] $HAMNIX_ISO not found — run scripts/build_iso.sh first." >&2
    exit 1
fi

# run_qemu LABEL BANNER_REGEX -- QEMU_ARGS...
#
# Two named args (label + regex) then the QEMU argv. The regex is taken
# explicitly because the two passes look for different banners now:
#   BIOS pass: kernel banner (multiboot1 -> start_kernel())
#   UEFI pass: EFI stub marker (direct PE/COFF entry)
run_qemu() {
    local label="$1"; shift
    local banner_re="$1"; shift
    local logfile
    logfile=$(mktemp --tmpdir hamnix-iso-${label}.XXXXXX.log)
    echo "[test_iso_qemu] === $label boot (timeout ${ISO_BOOT_TIMEOUT}s, banner=\"$banner_re\") ==="
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
    if grep -q -E "$banner_re" "$logfile"; then
        echo "[test_iso_qemu] $label: banner detected (\"$banner_re\")."
        rm -f "$logfile"
        return 0
    fi
    echo "[test_iso_qemu] $label: banner NOT detected in serial log ($logfile)." >&2
    return 1
}

# --- Pass 1: legacy BIOS ---
# Goes through SeaBIOS -> grub-pc -> multiboot1 -> kernel banner.
run_qemu "BIOS" "$BANNER_RE" -cdrom "$HAMNIX_ISO"
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
    # UEFI pass uses the EFI-stub-specific marker — direct PE/COFF entry,
    # no GRUB-EFI in the boot path.
    run_qemu "UEFI" "$UEFI_BANNER_RE" -bios "$OVMF_RW" -cdrom "$HAMNIX_ISO"
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
