#!/usr/bin/env bash
# scripts/build_user.sh - assemble + link userland binaries.
#
# For now we have exactly one user binary: user/init.S → build/init.elf
# (elf32-i386 wrapper with 64-bit code inside, just like the kernel's
# own wrapper). The output ELF is read by scripts/build_initramfs.py
# and embedded into the cpio archive as /init.
#
# Run this whenever you touch a user/*.S file or the linker script.
# scripts/build_initramfs.py is what gets called next.

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

mkdir -p build/user

as --32 -o build/user/init.o user/init.S
ld -m elf_i386 -nostdlib -static \
   -T user/init.lds \
   -o build/user/init.elf \
   build/user/init.o

echo "[build_user] wrote $(pwd)/build/user/init.elf"
file build/user/init.elf
