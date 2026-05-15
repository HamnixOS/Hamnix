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

build_one() {
    local name="$1"
    as --32 -o "build/user/${name}.o" "user/${name}.S"
    ld -m elf_i386 -nostdlib -static \
       -T user/init.lds \
       -o "build/user/${name}.elf" \
       "build/user/${name}.o"
    echo "[build_user] wrote $(pwd)/build/user/${name}.elf"
    file "build/user/${name}.elf"
}

build_one init
build_one hello
build_one echo

# Hamnix-compiled userland binaries (M16.35: the shell).
echo "[build_user] compiling user/hamsh.ad -> build/user/hamsh.elf"
python3 -m compiler.adder compile \
    --target=x86_64-adder-user \
    user/hamsh.ad \
    -o build/user/hamsh.elf
file build/user/hamsh.elf
