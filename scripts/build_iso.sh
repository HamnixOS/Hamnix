#!/usr/bin/env bash
# scripts/build_iso.sh - Build a hybrid (BIOS + UEFI) bootable ISO for Hamnix.
#
# Pipeline:
#   1. Ensure build/hamnix-vmlinux.elf exists (rebuild via run_x86_bare's
#      build steps if missing).
#   2. Stage build/iso/boot/hamnix.elf + grub.cfg.
#   3. Invoke grub-mkrescue to produce build/hamnix.iso (hybrid: legacy
#      BIOS via grub-pc-bin + UEFI via grub-efi-amd64-bin, xorriso as the
#      ISO writer, mtools to mash the EFI FAT image together).
#
# The resulting ISO is bootable in QEMU (with or without OVMF) and can
# be written to a USB stick with dd (see docs/BOOT.md).
#
# Required Debian packages: grub-pc-bin grub-efi-amd64-bin xorriso mtools
#
# Env overrides:
#   HAMNIX_ISO_OUT  output path           (default: build/hamnix.iso)
#   HAMNIX_KERNEL   kernel ELF to embed   (default: build/hamnix-vmlinux.elf)

set -euo pipefail

PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

# Serialize with the rest of the build pipeline: if a test or run_x86_bare
# is currently rebuilding the kernel ELF, we must not race them.
# shellcheck source=_build_lock.sh
source "$PROJ_ROOT/scripts/_build_lock.sh"

HAMNIX_KERNEL="${HAMNIX_KERNEL:-build/hamnix-vmlinux.elf}"
HAMNIX_ISO_OUT="${HAMNIX_ISO_OUT:-build/hamnix.iso}"
ISO_STAGE="build/iso"

# Sanity-check required host tools up front so we fail with a clear
# message rather than a cryptic grub-mkrescue error.
need_tool() {
    if ! command -v "$1" >/dev/null 2>&1; then
        echo "[build_iso] ERROR: '$1' not found in PATH." >&2
        echo "[build_iso]   apt-get install grub-pc-bin grub-efi-amd64-bin xorriso mtools" >&2
        exit 1
    fi
}
need_tool grub-mkrescue
need_tool xorriso
need_tool mformat

# Rebuild the kernel ELF if it isn't already there. We deliberately do
# not force-rebuild on every iso invocation — keeping the iso build
# cheap and predictable when the kernel ELF is already current.
if [ ! -f "$HAMNIX_KERNEL" ]; then
    echo "[build_iso] $HAMNIX_KERNEL missing — running full kernel build."
    bash scripts/build_user.sh
    bash scripts/build_modules.sh
    python3 scripts/build_initramfs.py
    python3 -m compiler.adder compile \
        --target=x86_64-bare-metal \
        init/main.ad \
        -o "$HAMNIX_KERNEL"
fi

echo "[build_iso] Using kernel: $HAMNIX_KERNEL"
file "$HAMNIX_KERNEL"

# Verify the multiboot1 magic before we bother grub. If the magic is
# missing, grub will silently boot to an unhelpful "you need to load
# the kernel first" prompt.
if ! od -An -tx4 -N8192 "$HAMNIX_KERNEL" | tr -s ' \n' '\n' | grep -q '^1badb002$'; then
    echo "[build_iso] ERROR: multiboot1 magic 0x1BADB002 not found in first 8 KiB of $HAMNIX_KERNEL" >&2
    exit 1
fi

# Clean staging dir from any previous run so leftover files (e.g. a
# stale grub.cfg) can't sneak into the new ISO.
rm -rf "$ISO_STAGE"
mkdir -p "$ISO_STAGE/boot/grub"
cp "$HAMNIX_KERNEL" "$ISO_STAGE/boot/hamnix.elf"

# grub.cfg: a single Hamnix entry that loads our multiboot1 kernel.
# `set timeout=2` makes the menu auto-pick the default after 2s so
# `qemu -nographic` runs don't hang waiting for a keypress.
cat > "$ISO_STAGE/boot/grub/grub.cfg" <<'GRUB_EOF'
set timeout=2
set default=0

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
# `-J` is implied by grub-mkrescue. We pass `--` so anything after is
# forwarded to xorriso unchanged (none for now).
echo "[build_iso] Running grub-mkrescue -> $HAMNIX_ISO_OUT"
grub-mkrescue -o "$HAMNIX_ISO_OUT" "$ISO_STAGE" 2>&1 | tail -20

if [ ! -f "$HAMNIX_ISO_OUT" ]; then
    echo "[build_iso] ERROR: grub-mkrescue did not produce $HAMNIX_ISO_OUT" >&2
    exit 1
fi

ISO_BYTES=$(stat -c%s "$HAMNIX_ISO_OUT")
echo "[build_iso] Done: $HAMNIX_ISO_OUT  ($ISO_BYTES bytes)"
echo "[build_iso] Test with:  bash scripts/test_iso_qemu.sh"
