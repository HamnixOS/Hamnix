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
build_one stdin_demo                   # used by scripts/test_stdin.sh

# Hamnix-compiled userland binaries.
build_adder_user() {
    local name="$1"
    echo "[build_user] compiling user/${name}.ad -> build/user/${name}.elf"
    python3 -m compiler.adder compile \
        --target=x86_64-adder-user \
        "user/${name}.ad" \
        -o "build/user/${name}.elf"
    file "build/user/${name}.elf"
}

build_adder_user hamsh                # M16.35: interactive shell
build_adder_user ps                   # M16.36: dumps /proc snapshots
build_adder_user echo                 # M16.37: writes argv to stdout
build_adder_user cat                  # M16.37: streams files to stdout
build_adder_user dup_demo             # M16.41: exercises sys_dup / sys_dup2
