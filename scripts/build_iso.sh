#!/usr/bin/env bash
# scripts/build_iso.sh - Build a hybrid (BIOS + UEFI) bootable ISO for Hamnix.
#
# Pipeline:
#   1. Ensure build/hamnix-kernel.elf exists (rebuild via run_x86_bare's
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
#   HAMNIX_KERNEL    kernel ELF to embed     (default: build/hamnix-kernel.elf)
#   HAMNIX_EFI_STUB  PE/COFF stub output     (default: build/hamnix-bootx64.efi)

set -euo pipefail

PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

# Serialize with the rest of the build pipeline: if a test or run_x86_bare
# is currently rebuilding the kernel ELF, we must not race them.
# shellcheck source=_build_lock.sh
source "$PROJ_ROOT/scripts/_build_lock.sh"

HAMNIX_KERNEL="${HAMNIX_KERNEL:-build/hamnix-kernel.elf}"
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
# A stale build/hamnix-kernel.elf is the more dangerous failure mode
# than a couple of redundant seconds of compile time — for instance,
# a kernel built with the legacy asm /init.elf (which exec'd /hello)
# would boot on real hardware then halt because /hello no longer
# exists. The ISO is the user-facing artifact; treat it as fresh.
echo "[build_iso] Rebuilding userland + initramfs + rootfs + kernel ELF."
bash scripts/build_user.sh
bash scripts/build_modules.sh
# Use the DEFAULT /init (build/user/init.elf — the shim built by
# build_user.sh). The shim execs /bin/hamsh with the boot rc
# /etc/rc.boot; hamsh-as-PID-1 sources that rc (the namespace recipe
# + boot services, all in the hamsh language) and then drops the
# booting user to an interactive shell. This is the user-facing
# real-hardware boot path. Test scripts that need a different first
# task override /init with their own INIT_ELF fixture.
python3 scripts/build_initramfs.py

# Build the ext4 rootfs image that will become partition 3 of the
# ISO (live-USB-style layout, see docs/rootfs_partition.md). The
# bulk of distro content — real Debian apt/dpkg, busybox, userland
# binaries — lives in the rootfs image; the cpio embedded above is
# kept SMALL (init + hamsh + framework .kos + /etc/rc.boot only).
# This is what lifts us past the FAT12 ~250 MB ESP ceiling and lets
# Hamnix carry 1 GB+ of distro content in the namespace.
HAMNIX_ROOTFS_IMG="${HAMNIX_ROOTFS_IMG:-build/hamnix-rootfs.img}"
HAMNIX_ROOTFS_OUT="$HAMNIX_ROOTFS_IMG" python3 scripts/build_rootfs_img.py

# Stale/partial-intermediate guard. Belt-and-braces for the
# recurring "multiboot1 magic not found" false failure (the primary
# root cause is the SIGPIPE race fixed in the magic check below):
#
#   `ld` writes its output file IN PLACE, incrementally, and is NOT
#   atomic. If a prior build_iso.sh (or any test_*.sh that wraps it)
#   is killed mid-link — agents routinely `timeout` their boot tests,
#   and cron kills runs — `ld` leaves a truncated/partial ELF sitting
#   at the final path build/hamnix-kernel.elf. The multiboot1 magic
#   lives at file offset 0x1000; a file truncated before that point
#   has no magic.
#
# Fix, in two parts:
#   1. Delete any leftover build/hamnix-kernel.elf up front, so the
#      magic check can never see a stale partial file from an aborted
#      prior run.
#   2. Compile to a unique temp path in build/, then `mv` it into the
#      final name. A rename within the same filesystem is atomic — a
#      reader either sees the complete file or no file at all, never a
#      half-written prefix. If THIS run is interrupted mid-link, only
#      the temp file is damaged; the final name is never a partial.
rm -f "$HAMNIX_KERNEL"
KERNEL_TMP="${HAMNIX_KERNEL}.tmp.$$"
rm -f "$KERNEL_TMP"
# Clean any orphaned *.tmp.* from earlier interrupted runs so build/
# doesn't accumulate junk (best-effort; never fatal).
rm -f "${HAMNIX_KERNEL}".tmp.* 2>/dev/null || true
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$KERNEL_TMP"
if [ ! -f "$KERNEL_TMP" ]; then
    echo "[build_iso] ERROR: compiler did not produce $KERNEL_TMP" >&2
    exit 1
fi
# Flush the freshly-linked ELF to stable storage, then atomically
# publish it under the final name. The magic check below therefore
# runs strictly AFTER the file is fully written and renamed into place.
sync "$KERNEL_TMP" 2>/dev/null || sync
mv -f "$KERNEL_TMP" "$HAMNIX_KERNEL"

echo "[build_iso] Using kernel: $HAMNIX_KERNEL"
file "$HAMNIX_KERNEL"

# Verify the multiboot1 magic before we bother grub. If the magic is
# missing, grub will silently boot to an unhelpful "you need to load
# the kernel first" prompt.
#
# ROOT CAUSE of the recurring spurious "multiboot1 magic not found"
# false failure (do NOT revert this to the old one-liner):
#
#   The old check was:
#       od ... | tr ... | grep -q '^1badb002$'
#   under `set -o pipefail`. `grep -q` exits the instant it sees the
#   first match — i.e. as soon as the magic word streams past. When
#   `grep` then closes the read end of the pipe, the still-running
#   upstream `tr` (which has ~8 KiB more to write) gets SIGPIPE and
#   dies with exit status 141 (128 + SIGPIPE). With `pipefail`, the
#   pipeline's status becomes that rightmost non-zero 141, the `if !`
#   negates it to "true", and the build aborts — even though the
#   magic was found. It is intermittent purely on scheduling: if `tr`
#   happens to flush its whole output before `grep -q` exits, the run
#   succeeds (PIPESTATUS 0 0 0); otherwise it fails (PIPESTATUS
#   0 141 0). Measured ~2-in-3 spurious failures under load.
#
# FIX: materialise the dump into a variable FIRST (a command
# substitution — no pipe is live while we search), then search the
# string with bash's own pattern match. No process can be SIGPIPE'd,
# so the result depends only on the file contents, never on timing.
# By construction (atomic mv above) this also reads a complete,
# freshly-built ELF, never a stale/partial one.
MAGIC_DUMP=$(od -An -tx4 -N8192 "$HAMNIX_KERNEL" | tr -s ' \n' ' ')
if [[ " $MAGIC_DUMP " != *" 1badb002 "* ]]; then
    KERNEL_SIZE=$(stat -c%s "$HAMNIX_KERNEL" 2>/dev/null || echo '?')
    echo "[build_iso] ERROR: multiboot1 magic 0x1BADB002 not found in first 8 KiB of $HAMNIX_KERNEL" >&2
    echo "[build_iso]   file size = ${KERNEL_SIZE} bytes; magic is expected at offset 0x1000." >&2
    echo "[build_iso]   This ELF was just freshly built and atomically renamed into place," >&2
    echo "[build_iso]   and the check no longer races on SIGPIPE, so a stale/partial" >&2
    echo "[build_iso]   intermediate is ruled out — this is a genuine kernel-image" >&2
    echo "[build_iso]   regression. Inspect arch/x86/boot/header.S and the linker" >&2
    echo "[build_iso]   script arch/x86/kernel/kernel.lds." >&2
    exit 1
fi

# ---- Build the native UEFI PE/COFF stub -----------------------------------
#
# The stub is a tiny standalone PE32+ EFI_APPLICATION assembled from
# arch/x86/boot/efi_stub.S. It currently does the EFI handshake (stash
# the EFI handle + system table, print "[hamnix] EFI entry reached",
# call GetMemoryMap + ExitBootServices, print "[hamnix] post-EFI
# handoff complete") and then halts.
#
# Why it still halts instead of `jmp _x86_start_after_loader` (which is
# all the rest of the wiring is structured around): the M16.111+M16.120
# wave assumed the kernel ELF and this stub could be merged into ONE
# hybrid binary so the stub could reach kernel symbols. The detailed
# diagnosis (post-M16.124) is in efi_stub.S's header comment — four
# independent constraints (B1..B4) make "one file is both ELF AND PE+"
# infeasible without restructuring the kernel image format. The cron's
# two real options out (PATH A: UEFI-side ELF loader in this stub;
# PATH B: bzImage-style flat-binary output) are also documented there
# and in docs/BOOT.md's Known-limitations section. Neither was picked
# this round — this commit only updates the documentation to reflect
# the actual blocker so the next agent doesn't reattempt the merge.
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

# M16.125 PATH A: ship a wide (16 MiB) ESP containing our PE stub
# AND the kernel ELF, sized to fit our ~3.8 MB kernel.elf.
#
# Strategy:
#   1. Pre-build the wide ESP FAT image with stub + kernel.
#   2. Run grub-mkrescue normally for the BIOS-bootable side.
#   3. Re-master the ISO with xorriso: drop the small grub-efi
#      ESP, replace it with our wide ESP, and DROP THE EL TORITO
#      UEFI alt-platform record (BIOS path keeps its own El Torito
#      i386-pc record). Without an El Torito UEFI record, OVMF
#      falls through to the GPT ESP partition — which we resize +
#      retarget to point at our wide ESP appended at end of ISO.
#
# Why dropping El Torito UEFI is OK:
#   - The El Torito UEFI alt-platform record points at a 5760-sector
#     /efi.img inside the ISO9660 region — too small for our kernel.
#     We can't enlarge it without corrupting ISO9660 file data.
#   - GPT-based UEFI boot is the modern path: every UEFI machine
#     shipped in the last decade supports it. The El Torito UEFI
#     record was a transitional design from the bzImage / CD-only
#     era.
#   - The BIOS-side El Torito record (platform_id=0x00 i386-pc)
#     stays in place, so BIOS boot still works.
echo "[build_iso] Pre-building wide ESP image with stub + kernel"
PATCH_TMP=$(mktemp -d)
trap 'rm -rf "$EFI_STUB_TMP" "$PATCH_TMP"' EXIT
WIDE_ESP_IMG="$PATCH_TMP/efi_wide.img"
# 24 MB FAT12 holds our 8 KB stub + the ~10 MB higher-half ELF64
# kernel + headroom for growth. (The kernel grew past the old 8 MB
# budget when it moved to elf64-x86-64 / higher-half.)
# WHY FAT12 (and not FAT16/FAT32):
#   OVMF on Debian rejects El Torito UEFI alt-platform images that
#   carry a FAT16 or FAT32 filesystem — "Not Found" from BdsDxe even
#   when the ESP partition is valid and contains BOOTX64.EFI. Switching
#   the ESP to FAT12 ("mformat" without -F, with explicit -h/-s/-t
#   geometry) makes OVMF load BOOTX64.EFI cleanly.
#   Verified empirically: a 4 MB FAT16 ESP fails with "Not Found"; a
#   4 MB FAT12 ESP with the same contents succeeds and "[hamnix] EFI
#   entry reached" appears on the serial console.
# WHY -c 128 (64 KB clusters, mtools' max): FAT12 has only 4084 usable
#   clusters, so at our chosen size the cluster size must keep us
#   under that ceiling — 128 MB / 64 KB = 2048 clusters, comfortably
#   FAT12. We can't go larger than -c 128 (mformat rejects -c 256 as
#   out-of-range; 128 sectors * 512 B = 64 KiB is the cluster ceiling).
#   Therefore the true ESP ceiling under FAT12 is ~250 MB (4084 * 64 KB).
#   OVMF rejects FAT16/FAT32 so we can't escape that bound — see the
#   rootfs-on-separate-partition note below.
# WHY 32 MB (was 128 during the "rootfs in cpio" era): with the
#   rootfs migrated to its own ext4 partition (docs/rootfs_partition.md)
#   the kernel ELF no longer carries the full distro tree — it's back
#   to ~15-20 MB. A 32 MB ESP holds the kernel + EFI stub with
#   comfortable headroom. The 128 MB bridge bump is no longer needed.
# ROOTFS-ON-SEPARATE-PARTITION (active): partition 3 of this ISO is
#   the ext4 rootfs image. The kernel auto-discovers it at boot and
#   reads `.hamnix-roots` for sentinel-declared names; userspace
#   `bind '#distro' /n/distros` lights it up. See
#   scripts/build_rootfs_img.py.
WIDE_ESP_SIZE_MB=32
WIDE_ESP_SECTORS=$(( WIDE_ESP_SIZE_MB * 1024 * 1024 / 512 ))
dd if=/dev/zero of="$WIDE_ESP_IMG" bs=1M count="$WIDE_ESP_SIZE_MB" status=none
# Geometry: -h 64 -s 32 -t <tracks>. Each track = 32*512 = 16 KB.
# For 32 MB total: 32*1024*1024 / 16384 = 2048 tracks.
mformat -i "$WIDE_ESP_IMG" -h 64 -s 32 -c 32 \
        -t $(( WIDE_ESP_SIZE_MB * 64 )) -v HAMNIX ::
mmd -i "$WIDE_ESP_IMG" "::/EFI"
mmd -i "$WIDE_ESP_IMG" "::/EFI/BOOT"
mcopy -o -i "$WIDE_ESP_IMG" "$HAMNIX_EFI_STUB" "::/EFI/BOOT/BOOTX64.EFI"
mcopy -o -i "$WIDE_ESP_IMG" "$HAMNIX_KERNEL"   "::/hamnix-kernel.elf"
echo "[build_iso] Wide ESP contents:"
mdir -i "$WIDE_ESP_IMG" ::/          | sed 's/^/    /'
mdir -i "$WIDE_ESP_IMG" ::/EFI/BOOT/ | sed 's/^/    /'

# Stage the grub-pc-bin tree under our own control, then build the
# ISO with xorriso DIRECTLY using grub-mkrescue's exact argument
# shape — but with `-append_partition 2 0xef <wide.img>` + an
# El Torito EFI record bound to the appended partition replacing
# grub-mkrescue's small in-band efi.img.
#
# We run grub-mkrescue once into a throwaway ISO so it does its work
# of staging the i386-pc modules + GRUB core image + the hybrid MBR
# bytes. We extract its staged tree from the throwaway ISO, fold in
# our ISO_STAGE (boot/hamnix.elf + grub.cfg), and re-run xorriso
# without grub-mkrescue's intermediate efi.img build step.
echo "[build_iso] Stage 1: grub-mkrescue throwaway pass to capture i386-pc tree"
THROWAWAY_ISO="$PATCH_TMP/throwaway.iso"
grub-mkrescue -o "$THROWAWAY_ISO" "$ISO_STAGE" 2>&1 | tail -3

# Extract the GRUB-staged tree from the throwaway. Skip /efi.img
# (the small grub-efi-only ESP we don't want), /efi/ (grub-efi's
# private dir; we'll re-emit /efi/boot/bootx64.efi from our stub),
# /System/Library/* (HFS+/Mac compat — we're disabling HFS+).
GRUB_TREE="$PATCH_TMP/grub_tree"
mkdir -p "$GRUB_TREE"
xorriso -indev "$THROWAWAY_ISO" -osirrox on \
        -extract / "$GRUB_TREE" >/dev/null 2>&1
chmod -R u+w "$GRUB_TREE"
rm -f "$GRUB_TREE/efi.img"
rm -rf "$GRUB_TREE/efi"
rm -rf "$GRUB_TREE/System"
rm -f "$GRUB_TREE/.disk"/*.uuid 2>/dev/null || true

# Stage /efi/boot/bootx64.efi as a regular file (for firmware that
# reads from the ISO9660 tree rather than the ESP partition).
mkdir -p "$GRUB_TREE/efi/boot"
cp "$HAMNIX_EFI_STUB" "$GRUB_TREE/efi/boot/bootx64.efi"

# Stage the boot tree (hamnix.elf + grub.cfg) — these already lived
# in ISO_STAGE/boot/ and grub-mkrescue copied them through.
# (They're already in $GRUB_TREE/boot/ from the extract.)

# Now build the final ISO with xorriso. The argument shape mirrors
# grub-mkrescue's invocation, minus its in-band efi.img and plus our
# wide-ESP append.
#
# Why not `--efi-boot efi.img -efi-boot-part --efi-boot-image`:
#   - That flag-chain depends on an efi.img file existing inside the
#     source tree at a known path. grub-mkrescue auto-creates that
#     via mformat at a hardcoded 2880 KB size. To use it we'd need
#     to either re-implement grub-mkrescue's mformat call (which
#     would still produce a 2880 KB ESP) or patch the file
#     post-creation. Both lose round-trips.
#   - `-append_partition` + `efi_path=--interval:appended_partition_N:all::`
#     skips that whole dance: the ESP partition source is our
#     pre-built file, declared by file path, no in-tree efi.img
#     needed.
# Drop the wide ESP into the source tree as `efi.img` so xorriso can
# bind both the El Torito UEFI alt-platform record AND a GPT ESP
# partition to it via `--efi-boot efi.img -efi-boot-part`. This is
# the same convention grub-mkrescue uses, just with our oversized
# image. The trailing `--efi-boot-image` makes xorriso also expose
# the file as a regular GPT ESP partition (mirrors grub-mkrescue's
# `-efi-boot-part --efi-boot-image` chain).
cp "$WIDE_ESP_IMG" "$GRUB_TREE/efi.img"

echo "[build_iso] Stage 2: xorriso direct build with wide ESP + rootfs ext4"
rm -f "$HAMNIX_ISO_OUT"
# Why -append_partition 3 0x83 <rootfs.img>:
#   * Partition 1: BIOS boot (existing, GPT-resident hybrid MBR)
#   * Partition 2: ESP (kernel + EFI stub, FAT12 via --efi-boot above)
#   * Partition 3: ext4 rootfs (NEW — Linux native, type 0x83)
# OVMF's GPT walker exposes all three to the firmware, but the kernel
# itself just needs the ext4 magic on partition 3 — the kernel scans
# every registered block device's superblock area at boot and mounts
# the first one carrying 0xEF53 at byte offset 1024.
xorriso -as mkisofs \
        -graft-points \
        -b boot/grub/i386-pc/eltorito.img \
        -no-emul-boot \
        -boot-load-size 4 \
        -boot-info-table \
        --grub2-boot-info \
        --grub2-mbr /usr/lib/grub/i386-pc/boot_hybrid.img \
        -eltorito-alt-boot \
        --efi-boot efi.img \
        -efi-boot-part --efi-boot-image \
        --protective-msdos-label \
        -append_partition 3 0x83 "$HAMNIX_ROOTFS_IMG" \
        -o "$HAMNIX_ISO_OUT" \
        -r "$GRUB_TREE" \
        --sort-weight 0 / \
        --sort-weight 1 /boot \
        2>&1 | tail -15

if [ ! -f "$HAMNIX_ISO_OUT" ]; then
    echo "[build_iso] ERROR: xorriso did not produce $HAMNIX_ISO_OUT" >&2
    exit 1
fi

# ---- Verify the rebuilt ISO has our wide ESP -------------------------
#
# The xorriso rebuild above used $WIDE_ESP_IMG as the efi.img source,
# so both the El Torito UEFI alt-platform record and the GPT ESP
# partition should now point at a 16 MiB FAT volume containing our
# stub and the kernel ELF.
echo "[build_iso] Verifying ISO copies of BOOTX64.EFI + kernel:"
VERIFY_TMP=$(mktemp -d)
trap 'rm -rf "$EFI_STUB_TMP" "$PATCH_TMP" "$VERIFY_TMP"' EXIT
EXPECTED_EFI_SHA=$(sha256sum "$HAMNIX_EFI_STUB" | awk '{print $1}')
EXPECTED_KERNEL_SHA=$(sha256sum "$HAMNIX_KERNEL" | awk '{print $1}')

# Locate the ESP partition in the GPT (sector + length, both used
# below by the verification dd). After our re-master, the ESP is
# named "Appended2" by xorriso's -append_partition convention rather
# than "EFI boot partition" — match by flag (esp) instead of by name.
ESP_INFO=$(/sbin/parted "$HAMNIX_ISO_OUT" unit s print 2>/dev/null \
           | grep -E "^ *[0-9]+ +[0-9]+s? +[0-9]+s? +[0-9]+s? .*\besp\b" \
           | head -1)
if [ -z "$ESP_INFO" ]; then
    echo "[build_iso] ERROR: could not locate ESP partition in $HAMNIX_ISO_OUT GPT" >&2
    /sbin/parted "$HAMNIX_ISO_OUT" unit s print >&2 || true
    exit 1
fi
ESP_START_SECTOR=$(echo "$ESP_INFO" | awk '{print $2}' | tr -d 's')
ESP_LENGTH_SECTORS=$(echo "$ESP_INFO" | awk '{print $4}' | tr -d 's')
echo "[build_iso] ESP partition at sector $ESP_START_SECTOR, length $ESP_LENGTH_SECTORS"

# 1) BOOTX64.EFI + hamnix-kernel.elf inside the GPT ESP partition.
dd if="$HAMNIX_ISO_OUT" of="$VERIFY_TMP/esp.img" \
   bs=512 skip="$ESP_START_SECTOR" count="$ESP_LENGTH_SECTORS" \
   status=none
mcopy -o -i "$VERIFY_TMP/esp.img" "::/EFI/BOOT/BOOTX64.EFI" \
                                  "$VERIFY_TMP/esp_bootx64.efi"
GPT_SHA=$(sha256sum "$VERIFY_TMP/esp_bootx64.efi" | awk '{print $1}')
if [ "$EXPECTED_EFI_SHA" != "$GPT_SHA" ]; then
    echo "[build_iso] ERROR: GPT ESP \\EFI\\BOOT\\BOOTX64.EFI content mismatch" >&2
    exit 1
fi
mcopy -o -i "$VERIFY_TMP/esp.img" "::/hamnix-kernel.elf" \
                                  "$VERIFY_TMP/esp_kernel.elf"
ESP_KERNEL_SHA=$(sha256sum "$VERIFY_TMP/esp_kernel.elf" | awk '{print $1}')
if [ "$EXPECTED_KERNEL_SHA" != "$ESP_KERNEL_SHA" ]; then
    echo "[build_iso] ERROR: GPT ESP \\hamnix-kernel.elf content mismatch" >&2
    exit 1
fi
echo "[build_iso]   GPT ESP \\EFI\\BOOT\\BOOTX64.EFI : $(stat -c%s "$VERIFY_TMP/esp_bootx64.efi") bytes, sha matches stub"
echo "[build_iso]   GPT ESP \\hamnix-kernel.elf    : $(stat -c%s "$VERIFY_TMP/esp_kernel.elf") bytes, sha matches kernel"

# Verify the rootfs partition lives in the GPT at partition 3 and
# carries an ext4 superblock. parted's per-partition flags don't
# mark ext4 specially, so we just confirm a 3rd partition exists
# beyond the ESP and that its first 1 KiB+ contains the 0xEF53 magic
# at offset 1024 (byte 0x438 of the partition).
ROOTFS_INFO=$(/sbin/parted "$HAMNIX_ISO_OUT" unit s print 2>/dev/null \
              | awk '/^ *3 +/ { print }')
if [ -z "$ROOTFS_INFO" ]; then
    echo "[build_iso] WARNING: no partition 3 in GPT (rootfs missing?)" >&2
    /sbin/parted "$HAMNIX_ISO_OUT" unit s print >&2 || true
else
    ROOTFS_START=$(echo "$ROOTFS_INFO" | awk '{print $2}' | tr -d 's')
    # Read 4 bytes at offset 1024 within the partition (sector 2,
    # byte 0). On an ext4 the bytes at offset 0x438..0x439 are the
    # little-endian magic 0xEF53.
    MAGIC_HEX=$(dd if="$HAMNIX_ISO_OUT" bs=512 \
                   skip=$((ROOTFS_START + 2)) count=1 status=none \
                | od -An -tx1 -N1024 \
                | tr -s ' \n' ' ' \
                | awk '{print $0}' \
                | cut -c2280-2285)
    # (Cheaper: just dump 2 bytes at exact offset.)
    MAGIC_BYTES=$(dd if="$HAMNIX_ISO_OUT" bs=1 \
                     skip=$(((ROOTFS_START * 512) + 1024 + 0x38)) \
                     count=2 status=none 2>/dev/null \
                  | od -An -tx1 | tr -d ' \n')
    if [ "$MAGIC_BYTES" = "53ef" ]; then
        echo "[build_iso]   rootfs partition 3 at sector $ROOTFS_START: ext4 magic 0xEF53 OK"
    else
        echo "[build_iso] WARNING: rootfs partition 3 at sector $ROOTFS_START: " \
             "magic bytes='$MAGIC_BYTES' (expected '53ef')" >&2
    fi
fi

ISO_BYTES=$(stat -c%s "$HAMNIX_ISO_OUT")
echo "[build_iso] Done: $HAMNIX_ISO_OUT  ($ISO_BYTES bytes)"
echo "[build_iso] BIOS path: GRUB + multiboot1 (unchanged)."
echo "[build_iso] UEFI path: native PE/COFF stub (no GRUB-EFI in the boot path)."
echo "[build_iso] Three partitions: BIOS boot + ESP (kernel) + ext4 rootfs."
echo "[build_iso] Test with:  bash scripts/test_iso_qemu.sh"
