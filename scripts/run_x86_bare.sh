#!/usr/bin/env bash
# scripts/run_x86_bare.sh - Boot the Hamnix bare-metal kernel under QEMU.
#
# Builds build/hamnix-kernel.elf from init/main.ad if needed, then runs it
# via `qemu-system-x86_64 -kernel`. Serial output (the banner) goes to
# stdout. Times out after a short window since the kernel halts after
# printing — that's the success signal.

set -euo pipefail

PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

mkdir -p build
ELF=build/hamnix-kernel.elf

# Build the userland binaries and kernel modules before regenerating
# the cpio archive — the archive embeds whatever sits in build/user/
# and build/mod/ at the time it's regenerated. All steps are
# idempotent and cheap; running them every invocation keeps the
# kernel ELF in sync with the user/ and mod/ source trees.
echo "[run_x86_bare] Building user/*.S -> build/user/"
bash scripts/build_user.sh

echo "[run_x86_bare] Building mod/*.S -> build/mod/"
bash scripts/build_modules.sh

echo "[run_x86_bare] Regenerating fs/initramfs_blob.S from cpio"
python3 scripts/build_initramfs.py

echo "[run_x86_bare] Compiling init/main.ad -> $ELF"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF"

echo "[run_x86_bare] file $ELF"
file "$ELF"

echo "[run_x86_bare] Multiboot magic check (first 16 bytes):"
od -An -tx4 -N16 "$ELF" || true

# Search the first 8 KiB for the multiboot magic 1BADB002 -- the spec
# requires the header to fall inside that window. We hex-dump it and
# look for the magic word in any 4-byte aligned position.
if ! od -An -tx4 -N8192 "$ELF" | tr -s ' \n' '\n' | grep -q '^1badb002$'; then
    echo "[run_x86_bare] ERROR: multiboot1 magic 0x1BADB002 not found in first 8 KiB"
    exit 1
fi
echo "[run_x86_bare] Multiboot magic OK."

echo "[run_x86_bare] Wrapping kernel in a BIOS GRUB ISO."
# The Hamnix kernel is now a true elf64-x86-64 higher-half image;
# QEMU's `-kernel` multiboot1 loader rejects 64-bit ELFs ("Cannot
# load x86-64 image"). GRUB's multiboot1 loader handles ELFCLASS64
# fine, so we boot a tiny BIOS GRUB ISO wrapping the kernel.
# shellcheck source=_kernel_iso.sh
source "$PROJ_ROOT/scripts/_kernel_iso.sh"
KISO="$(kernel_iso "$ELF")"

echo "[run_x86_bare] Booting in QEMU (10s timeout)..."
# -no-reboot stops QEMU exiting on triple fault; we use a hard timeout
# instead since success means "kernel halted after banner".
timeout 10s qemu-system-x86_64 \
    -cdrom "$KISO" \
    -smp 2 \
    -nographic \
    -no-reboot \
    -m 256M \
    -monitor none \
    -serial stdio \
    || rc=$?
rc=${rc:-0}

# timeout(1) returns 124 if it killed QEMU — for us that means the kernel
# is in HLT and behaved correctly. Treat 124 as success.
if [ "$rc" -eq 124 ] || [ "$rc" -eq 0 ]; then
    echo "[run_x86_bare] QEMU run finished (rc=$rc); banner should be above."
    exit 0
fi
echo "[run_x86_bare] QEMU exited with rc=$rc"
exit "$rc"
