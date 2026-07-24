#!/usr/bin/env bash
# scripts/build_installer_img_llvm.sh — package the LLVM-COMPILED installer
# kernel into the SAME OVMF+ext4 (ESP-only GPT) install medium that the native
# DE visual gate (scripts/test_de_visual_gate.sh) boots.
#
# WHY: test_de_visual_gate.sh boots the NATIVE kernel under OVMF from
# build/hamnix-installer-selftest.img and asserts the full windowed hamUI
# desktop (launch-queue app windows map). The LLVM-lane gate
# (test_de_visual_gate_llvm.sh) uses a DIFFERENT harness (BIOS-GRUB ISO + in-RAM
# selftest cpio) that maps 0 windows even for a clean NATIVE kernel — a
# harness-specific fork/exec gap, not an LLVM defect (see
# docs/de_visual_gate_llvm.md). The only honest, same-harness comparison is to
# boot the LLVM kernel through the NATIVE gate's OVMF+ext4 path. This script
# produces exactly that image.
#
# It reuses the artifacts scripts/build_installer_img.sh already emitted (run
# that FIRST, with HAMNIX_DE_SELFTEST=1, so the shipped ext4 rootfs carries the
# rc.5 DE self-test + the [visual_gate] launch-queue trio):
#   * the efi_stub PE/COFF loader        (build/hamnix-bootx64.efi)
#   * the Stage-6 INSTALLER initramfs blob that embeds /rootfs.sqfs
#     (build/initramfs_blob.S[.bin]) — the LLVM kernel is compiled against the
#     SAME blob so the ONLY variable vs native is the kernel codegen backend.
#
# Stages 7-8 below are byte-for-byte the media-ESP + ESP-only-GPT assembly from
# scripts/build_installer_img.sh, with the LLVM kernel substituted for
# hamnix-kernel.elf. efi_stub loads any elf64 higher-half image by walking its
# PT_LOAD phdrs (both kernels share arch/x86/kernel/kernel.lds + header.S +
# head_64.S), so the LLVM kernel boots through the identical firmware path.
#
# Env:
#   KLLVM_INSTALLER_ELF   LLVM installer kernel ELF
#                         (default build/kllvm_installer/hamnix_kernel_installer_llvm.elf)
#   EFI_STUB              PE/COFF stub (default build/hamnix-bootx64.efi)
#   OUT                   output image (default build/hamnix-installer-selftest-llvm.img)
set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"
export PATH="$PATH:/sbin:/usr/sbin"

KLLVM_INSTALLER_ELF="${KLLVM_INSTALLER_ELF:-build/kllvm_installer/hamnix_kernel_installer_llvm.elf}"
EFI_STUB="${EFI_STUB:-build/hamnix-bootx64.efi}"
OUT="${OUT:-build/hamnix-installer-selftest-llvm.img}"

for f in "$KLLVM_INSTALLER_ELF" "$EFI_STUB"; do
    [ -f "$f" ] || { echo "[llvm-img] ERROR: missing $f (run build_installer_img.sh + build_kernel_llvm.sh first)" >&2; exit 1; }
done
for t in mformat mcopy mmd dd; do command -v "$t" >/dev/null || { echo "[llvm-img] ERROR: '$t' not found" >&2; exit 1; }; done
PARTED="/sbin/parted"; [ -x "$PARTED" ] || PARTED="$(command -v parted || true)"
[ -n "$PARTED" ] || { echo "[llvm-img] ERROR: parted not found" >&2; exit 1; }

STUB_TMP=$(mktemp -d); trap 'rm -rf "$STUB_TMP"' EXIT

# Preallocated ESP log/oops files (same sizes/fill as build_installer_img.sh).
ESP_LOG_SRC="$STUB_TMP/log.txt"
head -c "${HAMNIX_ESP_LOG_SIZE:-262144}" /dev/zero | tr '\0' '\n' > "$ESP_LOG_SRC"
ESP_OOPS_SRC="$STUB_TMP/oops.bin"
head -c "${HAMNIX_ESP_OOPS_SIZE:-65536}" /dev/zero > "$ESP_OOPS_SRC"

# --- Stage 7: install-medium ESP (BOOTX64.EFI + LLVM installer kernel) ---
INSTALLER_KERNEL_BYTES=$(stat -c%s "$KLLVM_INSTALLER_ELF")
MEDIA_ESP_MB=$(( (INSTALLER_KERNEL_BYTES + (16 * 1024 * 1024)) / (1024 * 1024) ))
[ "$MEDIA_ESP_MB" -ge 32 ] || MEDIA_ESP_MB=32
MEDIA_ESP="$STUB_TMP/media_esp.img"
dd if=/dev/zero of="$MEDIA_ESP" bs=1M count="$MEDIA_ESP_MB" status=none
MEDIA_ESP_TRACKS=$(( MEDIA_ESP_MB * 64 ))
[ "$MEDIA_ESP_TRACKS" -le 65535 ] || MEDIA_ESP_TRACKS=65535
mformat -i "$MEDIA_ESP" -h 64 -s 32 -c 32 -t "$MEDIA_ESP_TRACKS" -v HAMNIXINST ::
mcopy -o -i "$MEDIA_ESP" "$ESP_LOG_SRC"  "::/LOG.TXT"
mcopy -o -i "$MEDIA_ESP" "$ESP_OOPS_SRC" "::/OOPS.BIN"
mmd -i "$MEDIA_ESP" "::/EFI"
mmd -i "$MEDIA_ESP" "::/EFI/BOOT"
mcopy -o -i "$MEDIA_ESP" "$EFI_STUB"            "::/EFI/BOOT/BOOTX64.EFI"
mcopy -o -i "$MEDIA_ESP" "$KLLVM_INSTALLER_ELF" "::/hamnix-kernel.elf"
echo "[llvm-img] Stage 7: install-medium ESP ${MEDIA_ESP_MB} MiB (LLVM kernel ${INSTALLER_KERNEL_BYTES} B)."

# --- Stage 8: assemble ESP-ONLY GPT install medium ---
ALIGN_MB=1
ESP_START_MB=$ALIGN_MB
ESP_END_MB=$(( ESP_START_MB + MEDIA_ESP_MB ))
TOTAL_MB=$(( ESP_END_MB + ALIGN_MB ))
rm -f "$OUT"
dd if=/dev/zero of="$OUT" bs=1M count="$TOTAL_MB" status=none
"$PARTED" -s "$OUT" mklabel gpt
"$PARTED" -s "$OUT" mkpart ESP fat32 "${ESP_START_MB}MiB" "${ESP_END_MB}MiB"
"$PARTED" -s "$OUT" set 1 esp on
dd if="$MEDIA_ESP" of="$OUT" bs=1M seek="$ESP_START_MB" conv=notrunc status=none

NPARTS=$("$PARTED" -s "$OUT" unit s print 2>/dev/null | awk '/^[ ]*[0-9]+/ {n++} END {print n+0}')
[ "$NPARTS" -eq 1 ] || { echo "[llvm-img] ERROR: $NPARTS partitions; must be 1 (ESP-only)" >&2; exit 1; }
IMG_BYTES=$(stat -c%s "$OUT")
echo "[llvm-img] DONE: $OUT  (${IMG_BYTES} bytes / $(( IMG_BYTES/1024/1024 )) MiB; ESP ${MEDIA_ESP_MB} MiB; LLVM kernel embeds the same /rootfs.sqfs as native)"
echo "[llvm-img] Boot the native acceptance against it:"
echo "[llvm-img]   INSTALLER_IMG=$OUT HAMNIX_SKIP_BUILD=1 bash scripts/test_de_visual_gate.sh"
