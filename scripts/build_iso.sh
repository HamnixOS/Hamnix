#!/usr/bin/env bash
# scripts/build_iso.sh - Build a hybrid (BIOS + UEFI) bootable ISO for Hamnix.
#
# Pipeline:
#   1. Ensure build/hamnix-vmlinux.elf exists (rebuild via run_x86_bare's
#      build steps if missing).
#   2. Build the native UEFI PE/COFF stub (build/hamnix-bootx64.efi) from
#      arch/x86/boot/efi_stub.S.
#   3. Stage build/iso/boot/hamnix.elf + grub.cfg.
#   4. Invoke grub-mkrescue to produce build/hamnix.iso (hybrid: legacy
#      BIOS via grub-pc-bin, plus a UEFI ESP image with grub-efi as a
#      fallback). xorriso is the underlying ISO writer.
#   5. Patch the embedded UEFI ESP image: replace its grub-efi-built
#      `\EFI\BOOT\BOOTX64.EFI` with our native PE32+ stub so UEFI firmware
#      executes Hamnix's own code with no GRUB middleman.
#
# The resulting ISO is bootable in QEMU (with or without OVMF) and can
# be written to a USB stick with dd (see docs/BOOT.md).
#
# Why two boot paths in one ISO:
#   - BIOS / SeaBIOS: still goes through GRUB (grub-pc-bin) + multiboot1.
#     The grub-mkrescue toolchain is the path of least resistance and the
#     kernel ELF doesn't have a BIOS-callable MBR signature of its own.
#   - UEFI: our native PE/COFF stub is the FIRST piece of Hamnix that
#     runs. No GRUB-EFI dependency, which is the M16.70 priority — UEFI
#     boot on real hardware via ISO image.
#
# Required Debian packages: grub-pc-bin grub-efi-amd64-bin xorriso mtools
#
# Env overrides:
#   HAMNIX_ISO_OUT   output path             (default: build/hamnix.iso)
#   HAMNIX_KERNEL    kernel ELF to embed     (default: build/hamnix-vmlinux.elf)
#   HAMNIX_EFI_STUB  PE/COFF stub output     (default: build/hamnix-bootx64.efi)

set -euo pipefail

PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

# Serialize with the rest of the build pipeline: if a test or run_x86_bare
# is currently rebuilding the kernel ELF, we must not race them.
# shellcheck source=_build_lock.sh
source "$PROJ_ROOT/scripts/_build_lock.sh"

HAMNIX_KERNEL="${HAMNIX_KERNEL:-build/hamnix-vmlinux.elf}"
HAMNIX_EFI_STUB="${HAMNIX_EFI_STUB:-build/hamnix-bootx64.efi}"
HAMNIX_ISO_OUT="${HAMNIX_ISO_OUT:-build/hamnix.iso}"
ISO_STAGE="build/iso"

# Sanity-check required host tools up front so we fail with a clear
# message rather than a cryptic grub-mkrescue error.
need_tool() {
    if ! command -v "$1" >/dev/null 2>&1; then
        echo "[build_iso] ERROR: '$1' not found in PATH." >&2
        echo "[build_iso]   apt-get install grub-pc-bin grub-efi-amd64-bin xorriso mtools binutils" >&2
        exit 1
    fi
}
need_tool grub-mkrescue
need_tool xorriso
need_tool mformat
need_tool mcopy
need_tool as
need_tool ld
# /sbin/parted: used to find the GPT-exposed ESP partition LBA so we
# can overwrite its bytes in-place. /sbin/ isn't in non-root PATH on
# every distro — check the full path explicitly.
if [ ! -x /sbin/parted ] && ! command -v parted >/dev/null 2>&1; then
    echo "[build_iso] ERROR: 'parted' not found in /sbin or PATH." >&2
    echo "[build_iso]   apt-get install parted" >&2
    exit 1
fi
need_tool dd
need_tool sha256sum

# Rebuild the kernel ELF if it isn't already there. We deliberately do
# not force-rebuild on every iso invocation — keeping the iso build
# cheap and predictable when the kernel ELF is already current.
# Always rebuild the userland + initramfs + kernel ELF for the ISO.
# A stale build/hamnix-vmlinux.elf is the more dangerous failure mode
# than a couple of redundant seconds of compile time — for instance,
# a kernel built with the legacy asm /init.elf (which exec'd /hello)
# would boot on real hardware then halt because /hello no longer
# exists. The ISO is the user-facing artifact; treat it as fresh.
echo "[build_iso] Rebuilding userland + initramfs + kernel ELF."
bash scripts/build_user.sh
bash scripts/build_modules.sh
# Use hamsh as /init so the booting user lands in an interactive
# shell. test scripts override this with their own fixtures; the
# default (and the human-facing real-hardware boot) is hamsh.
INIT_ELF=build/user/hamsh.elf python3 scripts/build_initramfs.py
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$HAMNIX_KERNEL"

echo "[build_iso] Using kernel: $HAMNIX_KERNEL"
file "$HAMNIX_KERNEL"

# Verify the multiboot1 magic before we bother grub. If the magic is
# missing, grub will silently boot to an unhelpful "you need to load
# the kernel first" prompt.
if ! od -An -tx4 -N8192 "$HAMNIX_KERNEL" | tr -s ' \n' '\n' | grep -q '^1badb002$'; then
    echo "[build_iso] ERROR: multiboot1 magic 0x1BADB002 not found in first 8 KiB of $HAMNIX_KERNEL" >&2
    exit 1
fi

# ---- Build the native UEFI PE/COFF stub -----------------------------------
#
# The stub is a tiny standalone PE32+ EFI_APPLICATION assembled from
# arch/x86/boot/efi_stub.S. It currently does only what is needed to prove
# the direct-UEFI boot path: stash the EFI handle + system table, print
# "[hamnix] EFI entry reached" over COM1, then halt. The full kernel
# handoff (ELF-load + jump to start_kernel) is a follow-up commit. See
# docs/BOOT.md for the rationale around the two-output split.
#
# Build invocation, dissected:
#   as --64 -o efi_stub.o efi_stub.S
#       True elf64-x86-64 object file. (The multiboot kernel ELF is
#       elf32-i386 because of multiboot1 constraints, but the EFI stub
#       has no such constraint — UEFI loads PE/COFF only.)
#   ld -m i386pep \
#      --subsystem 10 \              # 10 = IMAGE_SUBSYSTEM_EFI_APPLICATION
#      -e efi_main \                 # PE entry symbol
#      --image-base 0 \              # UEFI relocates the image anywhere; 0
#                                    #   keeps in-image references RVA-clean
#      --no-dynamic-linker \         # don't ask for an interp section
#      -nostdlib \                   # no startfiles, no libc
#      -o hamnix-bootx64.efi efi_stub.o
echo "[build_iso] Building native UEFI stub: $HAMNIX_EFI_STUB"
EFI_STUB_SRC="arch/x86/boot/efi_stub.S"
if [ ! -f "$EFI_STUB_SRC" ]; then
    echo "[build_iso] ERROR: $EFI_STUB_SRC missing." >&2
    exit 1
fi
EFI_STUB_TMP=$(mktemp -d)
trap 'rm -rf "$EFI_STUB_TMP"' EXIT
as --64 -o "$EFI_STUB_TMP/efi_stub.o" "$EFI_STUB_SRC"
ld -m i386pep --subsystem 10 -e efi_main --image-base 0 \
   --no-dynamic-linker -nostdlib \
   -o "$HAMNIX_EFI_STUB" "$EFI_STUB_TMP/efi_stub.o"

# Verify the stub really is a PE32+ EFI app — the rest of the pipeline
# assumes this. `file` reports something like:
#   "PE32+ executable for EFI (application), x86-64 (stripped to ...), N sections"
if ! file "$HAMNIX_EFI_STUB" | grep -q "PE32+ executable for EFI"; then
    echo "[build_iso] ERROR: $HAMNIX_EFI_STUB is not a PE32+ EFI application." >&2
    file "$HAMNIX_EFI_STUB" >&2
    exit 1
fi
echo "[build_iso] EFI stub: $(file -b "$HAMNIX_EFI_STUB")"

# ---- Stage the GRUB tree (BIOS path) --------------------------------------

# Clean staging dir from any previous run so leftover files (e.g. a
# stale grub.cfg) can't sneak into the new ISO.
rm -rf "$ISO_STAGE"
mkdir -p "$ISO_STAGE/boot/grub"
cp "$HAMNIX_KERNEL" "$ISO_STAGE/boot/hamnix.elf"

# grub.cfg: a single Hamnix entry that loads our multiboot1 kernel.
# Used by the BIOS path (SeaBIOS -> grub-pc) and as a fallback by the
# UEFI path IF some firmware ever fails to launch our PE stub and falls
# through to the grub-efi loader still present in the ESP image.
#
# `set timeout=2` makes the menu auto-pick the default after 2s so
# `qemu -nographic` runs don't hang waiting for a keypress.
cat > "$ISO_STAGE/boot/grub/grub.cfg" <<'GRUB_EOF'
set timeout=2
set default=0

# Under GRUB-EFI, multiboot1's MULTIBOOT_VIDEO_MODE flag (bit 2) in
# the kernel header is necessary but not sufficient: GRUB-EFI also
# requires that the gfx subsystem be told to KEEP the current GOP
# mode on hand-off (default: "text" → drops the framebuffer first).
# Without this set, GRUB-EFI prints "no suitable video mode found"
# and the multiboot framebuffer flag bit comes back clear — the
# kernel falls back to VGA, which is dark under UEFI.
#
# `keep` means "preserve whatever mode the firmware was using" —
# typically the OVMF / firmware-default 1024x768 or 1280x800. The
# `auto` value would let GRUB choose, but real boards often advertise
# only weird widescreen modes that fail GRUB's internal filters.
# `keep` always works because the mode is already programmed.
#
# Under legacy BIOS via grub-pc, GRUB does its own VBE probe and
# the variable is a no-op; the BIOS pass keeps working unchanged.
if loadfont unicode ; then
    set gfxmode=auto
    set gfxpayload=keep
    insmod gfxterm
    insmod all_video
    terminal_output gfxterm
fi

menuentry "Hamnix" {
    echo "Loading Hamnix..."
    multiboot /boot/hamnix.elf
    boot
}
GRUB_EOF

echo "[build_iso] Staging tree:"
find "$ISO_STAGE" -maxdepth 4 -print

# grub-mkrescue picks up both legacy BIOS (i386-pc) and UEFI (x86_64-efi)
# images automatically if the matching Debian packages are installed.
# It builds an MBR + ESP partition layout that's bootable in both modes.
# We patch the UEFI half of the result in the next step.
echo "[build_iso] Running grub-mkrescue -> $HAMNIX_ISO_OUT"
grub-mkrescue -o "$HAMNIX_ISO_OUT" "$ISO_STAGE" 2>&1 | tail -20

if [ ! -f "$HAMNIX_ISO_OUT" ]; then
    echo "[build_iso] ERROR: grub-mkrescue did not produce $HAMNIX_ISO_OUT" >&2
    exit 1
fi

# ---- Replace grub-efi BOOTX64.EFI with our native PE stub -----------------
#
# grub-mkrescue stages TWO copies of BOOTX64.EFI in the ISO:
#
#   (a) Inside an embedded ESP FAT image at ISO path `/efi.img`. The
#       El Torito boot catalog's UEFI alternate-platform entry points
#       at this image. Some firmwares (notably older edk2 builds) use
#       El Torito for UEFI boot from optical media.
#
#   (b) Directly on the ISO9660 / Rock Ridge filesystem as
#       `/efi/boot/bootx64.efi`. Modern OVMF (Debian package on this
#       host) ignores El Torito for UEFI and instead loads the file
#       at the standard `\EFI\BOOT\BOOTX64.EFI` path from the ISO's
#       primary filesystem. We discovered the hard way that NOT
#       patching this copy leaves the UEFI path still going through
#       GRUB.
#
# Patching strategy:
#   For (a): extract /efi.img, mcopy our stub into ::/EFI/BOOT/BOOTX64.EFI,
#   write back with xorriso -update.
#   For (b): xorriso -update_r our stub into /efi/boot/bootx64.efi.
#
# Both updates run under `-boot_image any keep` so the El Torito catalog
# and the hybrid MBR / GPT survive intact — otherwise the BIOS pass
# starts printing "Could not read from CDROM (code 0004)".
#
# Why post-process rather than build the ISO from scratch:
#   - grub-mkrescue knows the exact MBR / GPT / El Torito ceremony needed
#     for a HYBRID image (BIOS + UEFI from one ISO). Replicating that
#     by hand with xorriso primitives is ~50 lines of fragile dd math.
#   - The post-process is small, well-defined surgery (replace two known
#     files), robust against grub-mkrescue version drift.
echo "[build_iso] Patching UEFI BOOTX64.EFI -> Hamnix native PE stub"
PATCH_TMP=$(mktemp -d)
# Same trap target as the one set up earlier for the EFI stub temp dir.
trap 'rm -rf "$EFI_STUB_TMP" "$PATCH_TMP"' EXIT

ESP_IMG="$PATCH_TMP/efi.img"
xorriso -indev "$HAMNIX_ISO_OUT" \
        -osirrox on \
        -extract /efi.img "$ESP_IMG" \
        >/dev/null 2>&1

if [ ! -f "$ESP_IMG" ]; then
    echo "[build_iso] ERROR: failed to extract /efi.img from $HAMNIX_ISO_OUT" >&2
    exit 1
fi

# xorriso preserves the ISO's read-only mode bits on extraction. mtools
# needs write access to mutate the FAT in place.
chmod u+w "$ESP_IMG"

# Verify the ESP looks like we expect before we mutate it.
if ! mdir -i "$ESP_IMG" ::/EFI/BOOT/ >/dev/null 2>&1; then
    echo "[build_iso] ERROR: extracted /efi.img has no ::/EFI/BOOT/ tree" >&2
    exit 1
fi

# Overwrite the GRUB-EFI BOOTX64.EFI with our native PE stub.
# mcopy's `-o` flag overwrites without prompting.
mcopy -o -i "$ESP_IMG" "$HAMNIX_EFI_STUB" ::/EFI/BOOT/BOOTX64.EFI
echo "[build_iso] Patched ESP contents:"
mdir -i "$ESP_IMG" ::/EFI/BOOT/ | sed 's/^/    /'

# grub-mkrescue actually exposes the embedded ESP in THREE different
# ways simultaneously — all of which can be the firmware's boot path:
#
#   - /efi.img        ISO9660 file containing the FAT ESP image bytes
#   - El Torito UEFI  alt-platform entry pointing at /efi.img's LBA
#   - GPT partition 2 a real GPT partition whose LBA range overlaps
#                     /efi.img's bytes inside the ISO
#
# Most modern UEFI firmware (OVMF, Tianocore, AMI on modern boards)
# prefers the GPT route. Empirically, OVMF on Debian reads the GPT
# ESP partition and ignores both /efi.img and El Torito UEFI. If we
# only patch /efi.img through xorriso, the GPT path still serves the
# original GRUB-EFI blob and our stub never runs.
#
# Strategy: rewrite the ESP bytes IN PLACE in the ISO file, at the
# byte offset the GPT (and El Torito) BOTH reference. Because mtools
# overwriting a file inside an existing FAT preserves the FAT image's
# total size (we just rewrote file contents in pre-allocated clusters),
# the rewrite is byte-for-byte safe. No xorriso -commit, no LBA shuffle,
# no broken boot record.
#
# We also still patch the ISO9660 copy at /efi/boot/bootx64.efi
# (for firmware that finds it there) — for that we use xorriso
# -update_r in a SEPARATE pass with -boot_image any keep so the
# El Torito catalog is preserved.

# --- Patch 1: ESP partition bytes (GPT-visible + El Torito) -------------
#
# Locate the ESP partition by parsing the GPT directly with parted's
# machine-readable output. Hard-coding LBA 304/length 5760 would work
# today but breaks if a future grub-mkrescue changes the layout.
ESP_INFO=$(/sbin/parted "$HAMNIX_ISO_OUT" unit s print 2>/dev/null \
           | grep -E "^ *[0-9]+s? +[0-9]+s? +[0-9]+s? +[0-9]+s? +.*EFI" \
           | head -1)
if [ -z "$ESP_INFO" ]; then
    # Fallback: try by Flags=esp,boot if the partition name changed.
    ESP_INFO=$(/sbin/parted "$HAMNIX_ISO_OUT" unit s print 2>/dev/null \
               | grep -E "^ *[0-9]+ +[0-9]+s +[0-9]+s +[0-9]+s.*esp" \
               | head -1)
fi
if [ -z "$ESP_INFO" ]; then
    echo "[build_iso] ERROR: could not locate ESP partition in $HAMNIX_ISO_OUT GPT" >&2
    /sbin/parted "$HAMNIX_ISO_OUT" unit s print >&2 || true
    exit 1
fi
# Columns: <Number> <Start>s <End>s <Size>s ... — strip the trailing 's'.
ESP_START_SECTOR=$(echo "$ESP_INFO" | awk '{print $2}' | tr -d 's')
ESP_LENGTH_SECTORS=$(echo "$ESP_INFO" | awk '{print $4}' | tr -d 's')
echo "[build_iso] ESP partition at sector $ESP_START_SECTOR, length $ESP_LENGTH_SECTORS"

ESP_BYTES=$(( ESP_LENGTH_SECTORS * 512 ))
NEW_ESP_BYTES=$(stat -c%s "$ESP_IMG")
if [ "$ESP_BYTES" -ne "$NEW_ESP_BYTES" ]; then
    echo "[build_iso] ERROR: patched ESP size $NEW_ESP_BYTES != GPT-allocated $ESP_BYTES" >&2
    exit 1
fi

# In-place overwrite. `conv=notrunc` keeps the ISO trailing data
# intact; `seek=<sector>` positions us at the GPT-declared LBA.
dd if="$ESP_IMG" of="$HAMNIX_ISO_OUT" \
   bs=512 seek="$ESP_START_SECTOR" conv=notrunc status=none

# --- Patch 2: ISO9660 /efi/boot/bootx64.efi --------------------------
#
# Separate xorriso pass — `-update_r` replaces the named file inside
# the ISO9660 tree. `-boot_image any keep` preserves the El Torito
# catalog and the hybrid MBR. Different from -update used above (that
# one mutated a file's contents through a temporary file path inside
# the ISO; -update_r works against the ISO9660 directory tree).
xorriso -dev "$HAMNIX_ISO_OUT" \
        -boot_image any keep \
        -update "$HAMNIX_EFI_STUB" /efi/boot/bootx64.efi \
        -commit \
        >/dev/null 2>&1

# --- Verification ----------------------------------------------------
#
# Read the two copies of BOOTX64.EFI back out of the ISO and confirm
# each is byte-identical to our PE stub. Catches grub-mkrescue layout
# drift, mtools failing silently, dd-offset miscalculations, and
# xorriso reverting our changes — any of which would silently ship a
# UEFI ISO that chains back through GRUB.
echo "[build_iso] Verifying ISO copies of BOOTX64.EFI:"
VERIFY_TMP=$(mktemp -d)
trap 'rm -rf "$EFI_STUB_TMP" "$PATCH_TMP" "$VERIFY_TMP"' EXIT
EXPECTED_SHA=$(sha256sum "$HAMNIX_EFI_STUB" | awk '{print $1}')

# 1) /efi/boot/bootx64.efi on the ISO9660 filesystem.
xorriso -indev "$HAMNIX_ISO_OUT" -osirrox on \
        -extract /efi/boot/bootx64.efi "$VERIFY_TMP/iso_bootx64.efi" \
        >/dev/null 2>&1
chmod u+w "$VERIFY_TMP/iso_bootx64.efi"
ISO_SHA=$(sha256sum "$VERIFY_TMP/iso_bootx64.efi" | awk '{print $1}')
if [ "$EXPECTED_SHA" != "$ISO_SHA" ]; then
    echo "[build_iso] ERROR: /efi/boot/bootx64.efi content mismatch" >&2
    exit 1
fi
echo "[build_iso]   /efi/boot/bootx64.efi  : $(stat -c%s "$VERIFY_TMP/iso_bootx64.efi") bytes, sha matches stub"

# 2) BOOTX64.EFI inside the GPT-exposed ESP partition.
dd if="$HAMNIX_ISO_OUT" of="$VERIFY_TMP/esp.img" \
   bs=512 skip="$ESP_START_SECTOR" count="$ESP_LENGTH_SECTORS" \
   status=none
mcopy -o -i "$VERIFY_TMP/esp.img" ::/EFI/BOOT/BOOTX64.EFI "$VERIFY_TMP/esp_bootx64.efi"
GPT_SHA=$(sha256sum "$VERIFY_TMP/esp_bootx64.efi" | awk '{print $1}')
if [ "$EXPECTED_SHA" != "$GPT_SHA" ]; then
    echo "[build_iso] ERROR: GPT ESP \\EFI\\BOOT\\BOOTX64.EFI content mismatch" >&2
    exit 1
fi
echo "[build_iso]   GPT ESP \\EFI\\BOOT\\BOOTX64.EFI : $(stat -c%s "$VERIFY_TMP/esp_bootx64.efi") bytes, sha matches stub"

ISO_BYTES=$(stat -c%s "$HAMNIX_ISO_OUT")
echo "[build_iso] Done: $HAMNIX_ISO_OUT  ($ISO_BYTES bytes)"
echo "[build_iso] BIOS path: GRUB + multiboot1 (unchanged)."
echo "[build_iso] UEFI path: native PE/COFF stub (no GRUB-EFI in the boot path)."
echo "[build_iso] Test with:  bash scripts/test_iso_qemu.sh"
