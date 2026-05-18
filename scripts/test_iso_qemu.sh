#!/usr/bin/env bash
# scripts/test_iso_qemu.sh - Boot build/hamnix.iso in QEMU (BIOS + UEFI).
#
# Two passes:
#   1. Legacy BIOS via qemu-system-x86_64 -cdrom (default SeaBIOS).
#      Banner = the regular kernel banner; we go all the way through
#      GRUB → multiboot1 → start_kernel().
#   2. UEFI via -bios /usr/share/ovmf/OVMF.fd (only if OVMF.fd exists).
#      Banners = the native PE/COFF stub's TWO serial markers,
#      asserted in order:
#        a) "[hamnix] EFI entry reached"     — UEFI launched our PE
#                                              stub (no GRUB-EFI in
#                                              the path). Present
#                                              since M16.111.
#        b) "[hamnix] post-EFI handoff       — ExitBootServices()
#            complete"                         returned EFI_SUCCESS.
#                                              Proves firmware
#                                              actually relinquished
#                                              the platform; we are
#                                              now running with no
#                                              boot services behind
#                                              us, no firmware-timer
#                                              interrupts firing, no
#                                              hidden memory-manager
#                                              activity. New marker.
#      Why two markers and not one: marker (a) ONLY proves the PE/COFF
#      load worked. Marker (b) proves the full EFI exit handshake
#      (GetMemoryMap + ExitBootServices + MapKey-staleness retry)
#      went through. The stub halts after marker (b).
#
#      The full kernel handoff (the post-handshake `jmp
#      _x86_start_after_loader`) is blocked on a stack of constraints
#      that the post-M16.124 diagnosis spells out — see
#      arch/x86/boot/efi_stub.S's header comment (blockers B1..B4)
#      and docs/BOOT.md's Known-limitations section. The short
#      version: a single binary cannot be both elf32-i386 (every
#      `qemu -kernel` test asserts this) AND PE32+ at offset 0 of
#      the same file. Two real escape paths are sketched in the
#      header comment (UEFI-side ELF loader in the stub, OR a
#      bzImage-style flat output); neither has shipped yet, so the
#      test continues to assert (a)+(b) and the BIOS half remains
#      the only path that actually reaches a Hamnix banner.
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
#   UEFI_BANNER_RE     UEFI-pass primary banner  (default: EFI stub
#                                                  PE-entry marker)
#   UEFI_HANDOFF_RE    UEFI-pass post-handoff    (default: post-
#                       banner (REQUIRED)         ExitBootServices
#                                                  marker — proves
#                                                  firmware released
#                                                  the platform)
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
UEFI_HANDOFF_RE="${UEFI_HANDOFF_RE:-\[hamnix\] post-EFI handoff complete}"
OVMF_FD="/usr/share/ovmf/OVMF.fd"

if [ ! -f "$HAMNIX_ISO" ]; then
    echo "[test_iso_qemu] $HAMNIX_ISO not found — run scripts/build_iso.sh first." >&2
    exit 1
fi

# run_qemu LABEL BANNER_REGEX POST_REGEX -- QEMU_ARGS...
#
# Args:
#   LABEL          short identifier used in log lines + filenames
#   BANNER_REGEX   primary banner the pass must observe (required)
#   POST_REGEX     OPTIONAL second marker that MUST appear AFTER the
#                  primary banner. Used by the UEFI pass to assert
#                  that ExitBootServices succeeded — not just that
#                  PE/COFF entry was reached. Pass an empty string ""
#                  to skip the secondary assertion.
#   QEMU_ARGS...   the rest of qemu's argv
#
# Why two markers for UEFI:
#   The first marker only proves the PE loader executed our entry
#   point. The post-handoff marker only fires after the full
#   GetMemoryMap + ExitBootServices handshake completes — including
#   the MapKey-staleness retry loop. Catching it in the log proves
#   the EFI exit path actually worked, not just that we reached it.
run_qemu() {
    local label="$1"; shift
    local banner_re="$1"; shift
    local post_re="$1"; shift
    local logfile
    logfile=$(mktemp --tmpdir hamnix-iso-${label}.XXXXXX.log)
    if [ -n "$post_re" ]; then
        echo "[test_iso_qemu] === $label boot (timeout ${ISO_BOOT_TIMEOUT}s, banner=\"$banner_re\", post=\"$post_re\") ==="
    else
        echo "[test_iso_qemu] === $label boot (timeout ${ISO_BOOT_TIMEOUT}s, banner=\"$banner_re\") ==="
    fi
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
    if ! grep -q -E "$banner_re" "$logfile"; then
        echo "[test_iso_qemu] $label: primary banner NOT detected in serial log ($logfile)." >&2
        return 1
    fi
    echo "[test_iso_qemu] $label: primary banner detected (\"$banner_re\")."
    if [ -n "$post_re" ]; then
        # Enforce strict ORDER: post_re must appear AFTER banner_re
        # in the log. Otherwise a stray log fragment that happens
        # to match the post regex could falsely satisfy the
        # assertion.
        #
        # Implementation: use `grep -n` to get line numbers of the
        # first match of each pattern, then compare. Both regexes
        # are written in grep ERE shape (this is how BANNER_RE +
        # UEFI_HANDOFF_RE are documented) so reusing grep keeps
        # the regex dialect consistent.
        local banner_line post_line
        banner_line=$(grep -n -E "$banner_re" "$logfile" | head -1 | cut -d: -f1)
        post_line=$(grep -n -E "$post_re"  "$logfile" | head -1 | cut -d: -f1)
        if [ -z "$post_line" ]; then
            echo "[test_iso_qemu] $label: post-handoff marker (\"$post_re\") NOT detected ($logfile)." >&2
            return 1
        fi
        if [ -z "$banner_line" ] || [ "$post_line" -le "$banner_line" ]; then
            echo "[test_iso_qemu] $label: post-handoff marker (\"$post_re\") appears at or before primary banner — ordering violated ($logfile)." >&2
            return 1
        fi
        echo "[test_iso_qemu] $label: post-handoff marker detected (\"$post_re\")."
    fi
    rm -f "$logfile"
    return 0
}

# --- Pass 1: legacy BIOS ---
# Goes through SeaBIOS -> grub-pc -> multiboot1 -> kernel banner.
# No post-handoff marker needed (BIOS path reaches full start_kernel()
# already; the kernel banner subsumes "we got past the loader").
run_qemu "BIOS" "$BANNER_RE" "" -cdrom "$HAMNIX_ISO"
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
    # UEFI pass: assert BOTH markers, in order. The first proves
    # PE/COFF entry; the second proves ExitBootServices succeeded
    # (firmware actually released control). Together they prove the
    # EFI handoff path is complete end-to-end, modulo the pending
    # kernel-symbol reach that requires the binary-merge follow-up.
    run_qemu "UEFI" "$UEFI_BANNER_RE" "$UEFI_HANDOFF_RE" \
        -bios "$OVMF_RW" -cdrom "$HAMNIX_ISO"
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
