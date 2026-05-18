#!/usr/bin/env bash
# scripts/test_iso_qemu.sh - Boot build/hamnix.iso in QEMU (BIOS + UEFI).
#
# Two passes:
#   1. Legacy BIOS via qemu-system-x86_64 -cdrom (default SeaBIOS).
#      Banner = the regular kernel banner; we go all the way through
#      GRUB → multiboot1 → start_kernel().
#   2. UEFI via -bios /usr/share/ovmf/OVMF.fd (only if OVMF.fd exists).
#      As of M16.125 PATH A, the UEFI path now reaches start_kernel()
#      too via the ELF-loader bake-in (arch/x86/boot/efi_stub.S
#      SFSP-reads \hamnix-vmlinux.elf off the ESP, parses program
#      headers, copies PT_LOAD segments to their LMA, then jumps to
#      _x86_start_after_loader). The UEFI assertion now requires
#      BOTH the EFI handoff markers AND a deep kernel marker that
#      proves start_kernel() actually ran. Banners checked, in order:
#
#        a) "[hamnix] EFI entry reached"          — PE entry hit.
#        b) "[hamnix] post-EFI handoff complete"  — ExitBootServices()
#                                                    returned EFI_SUCCESS.
#        c) "cpio: registered N files from        — Kernel booted past
#            initramfs"                              e820 → memblock →
#                                                    cpio_init. Final
#                                                    proof the EFI ELF
#                                                    loader handed off
#                                                    cleanly to
#                                                    _x86_start_after_loader
#                                                    and start_kernel()
#                                                    ran far enough to
#                                                    parse the embedded
#                                                    initramfs.
#
#      Marker (a) proves the PE/COFF load worked. Marker (b) proves
#      the EFI exit handshake (GetMemoryMap + ExitBootServices +
#      MapKey-staleness retry) went through. Marker (c) is the new
#      M16.125 hurdle — it can only appear if the EFI stub's ELF
#      loader (PATH A from M16.124's diagnosis) successfully:
#         - opened \hamnix-vmlinux.elf via SFSP,
#         - copied every PT_LOAD segment to its LMA,
#         - installed identity-mapped page tables + a kernel-shape GDT,
#         - jumped to _x86_start_after_loader,
#      AND start_kernel() then ran far enough to call cpio_init().
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
# M16.125 PATH A: deep kernel marker that proves the EFI ELF loader
# handed off cleanly AND start_kernel() ran past e820 -> memblock ->
# fs_init() -> cpio_init(). Once `cpio: registered N files from
# initramfs` is on the wire, the EFI bring-up is end-to-end functional.
UEFI_KERNEL_RE="${UEFI_KERNEL_RE:-cpio: registered [0-9]+ files from initramfs}"
OVMF_FD="/usr/share/ovmf/OVMF.fd"

if [ ! -f "$HAMNIX_ISO" ]; then
    echo "[test_iso_qemu] $HAMNIX_ISO not found — run scripts/build_iso.sh first." >&2
    exit 1
fi

# run_qemu LABEL BANNER_REGEX POST_REGEX KERNEL_REGEX -- QEMU_ARGS...
#
# Args:
#   LABEL          short identifier used in log lines + filenames
#   BANNER_REGEX   primary banner the pass must observe (required)
#   POST_REGEX     OPTIONAL second marker that MUST appear AFTER the
#                  primary banner. Pass "" to skip.
#   KERNEL_REGEX   OPTIONAL third marker that MUST appear AFTER the
#                  post-handoff marker (used by the UEFI pass post-
#                  M16.125 to prove start_kernel() actually ran past
#                  cpio_init, not just that the EFI handoff completed).
#                  Pass "" to skip.
#   QEMU_ARGS...   the rest of qemu's argv
#
# Why three markers for UEFI:
#   - banner (a): proves the PE loader executed our entry point.
#   - post (b):   proves the GetMemoryMap + ExitBootServices handshake
#                 completed.
#   - kernel (c): proves the EFI stub's ELF loader (M16.125 PATH A)
#                 successfully copied PT_LOADs, set up identity
#                 paging + GDT, and jumped into the kernel — AND
#                 start_kernel() ran far enough to register
#                 initramfs files.
run_qemu() {
    local label="$1"; shift
    local banner_re="$1"; shift
    local post_re="$1"; shift
    local kernel_re="$1"; shift
    local logfile
    logfile=$(mktemp --tmpdir hamnix-iso-${label}.XXXXXX.log)
    local hdr="[test_iso_qemu] === $label boot (timeout ${ISO_BOOT_TIMEOUT}s, banner=\"$banner_re\""
    if [ -n "$post_re" ];   then hdr="$hdr, post=\"$post_re\""; fi
    if [ -n "$kernel_re" ]; then hdr="$hdr, kernel=\"$kernel_re\""; fi
    echo "$hdr) ==="
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
    if ! grep -a -q -E "$banner_re" "$logfile"; then
        echo "[test_iso_qemu] $label: primary banner NOT detected in serial log ($logfile)." >&2
        return 1
    fi
    echo "[test_iso_qemu] $label: primary banner detected (\"$banner_re\")."

    # Strict-order check: each subsequent marker must appear AFTER
    # the previous one's line number. Otherwise stray log fragments
    # could falsely satisfy a check.
    local banner_line post_line kernel_line
    banner_line=$(grep -a -n -E "$banner_re" "$logfile" | head -1 | cut -d: -f1)

    if [ -n "$post_re" ]; then
        post_line=$(grep -a -n -E "$post_re" "$logfile" | head -1 | cut -d: -f1)
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

    if [ -n "$kernel_re" ]; then
        kernel_line=$(grep -a -n -E "$kernel_re" "$logfile" | head -1 | cut -d: -f1)
        if [ -z "$kernel_line" ]; then
            echo "[test_iso_qemu] $label: kernel marker (\"$kernel_re\") NOT detected ($logfile)." >&2
            return 1
        fi
        local prev_line="${post_line:-$banner_line}"
        if [ -z "$prev_line" ] || [ "$kernel_line" -le "$prev_line" ]; then
            echo "[test_iso_qemu] $label: kernel marker (\"$kernel_re\") appears at or before prior marker — ordering violated ($logfile)." >&2
            return 1
        fi
        echo "[test_iso_qemu] $label: kernel marker detected (\"$kernel_re\")."
    fi

    rm -f "$logfile"
    return 0
}

# --- Pass 1: legacy BIOS ---
# Goes through SeaBIOS -> grub-pc -> multiboot1 -> kernel banner.
# No post-handoff or kernel marker — the banner subsumes "we got
# past the loader and into start_kernel()".
run_qemu "BIOS" "$BANNER_RE" "" "" -cdrom "$HAMNIX_ISO"
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
    # UEFI pass: assert all THREE markers in order. The first proves
    # PE/COFF entry; the second proves ExitBootServices succeeded;
    # the third proves the EFI ELF loader handed off to the kernel
    # and start_kernel() ran past cpio_init. Together they prove the
    # PATH A bake-in works end-to-end.
    run_qemu "UEFI" "$UEFI_BANNER_RE" "$UEFI_HANDOFF_RE" "$UEFI_KERNEL_RE" \
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
