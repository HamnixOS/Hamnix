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
build_adder_user ls                   # M16.46: directory listing
build_adder_user pwd                  # M16.47: print working dir
build_adder_user head                 # M16.57: first N lines
build_adder_user wc                   # M16.57: line/word/byte count
build_adder_user grep                 # M16.57: substring line filter
build_adder_user seq                  # M16.64: 1..N or M..N output
build_adder_user uname                # M16.64: system identification
build_adder_user true                 # M16.64: exit 0
build_adder_user false                # M16.64: exit 1
build_adder_user yes                  # M16.64: repeat-until-SIGINT
build_adder_user sleep                # M16.64: jiffies-based delay
build_adder_user sort                 # M16.64: insertion sort of stdin
build_adder_user tee                  # M16.64: fan stdin to stdout + file
build_adder_user rev                  # M16.64: per-line reverse
build_adder_user rm                   # M16.65: tmpfs unlink
build_adder_user touch                # M16.65: create-empty / truncate
build_adder_user mkdir                # M16.65: no-op stub (flat tmpfs)
build_adder_user basename             # M16.66: strip path prefix
build_adder_user dirname              # M16.66: keep path prefix
build_adder_user cut                  # M16.66: -c column / range slice
build_adder_user tr                   # M16.66: SRC->DST byte translate
build_adder_user od                   # M16.66: -An -tx1 hex dump
build_adder_user printf               # M16.66: %s/%d + \n/\t/\\ escapes
build_adder_user cp                   # M16.66: SRC->DST file copy (<=8 KiB)
build_adder_user whoami               # M16.67: prints "root"
build_adder_user id                   # M16.67: hard-wired uid=0(root) line
build_adder_user clear                # M16.67: ANSI clear-screen + home
build_adder_user hostname             # M16.67: /etc/hostname with fallback
build_adder_user date                 # M16.67: uptime-as-clock until RTC
build_adder_user more                 # M16.67: 24-line pager over stdin
build_adder_user find                 # M16.67: recursive listdir walk
build_adder_user diff                 # M16.67: byte-compare two files
build_adder_user motd  # M16.68: print /etc/motd
build_adder_user df                   # M16.70: dump /proc/mounts
build_adder_user du                   # M16.70: entry-count under path
build_adder_user tail                 # M16.70: last N lines of stdin
build_adder_user cmp                  # M16.70: byte-compare two files
build_adder_user which                # M16.74: PATH lookup tool
build_adder_user init2                # M16.74: Adder /sbin/init reading /etc/inittab
build_adder_user free                 # M16.74: /proc/meminfo as free table
build_adder_user uptime               # M16.74: /proc/uptime in seconds
build_adder_user mv                   # M16.74: copy + unlink (no rename(2))
build_adder_user ln                   # M16.74: placeholder for symlink/hardlink
build_adder_user cal                  # M16.74: hard-coded May 2026 month grid
build_adder_user expr                 # M16.74: A OP B for + - * /
build_adder_user test                 # M16.74: -z/-n/=/!= predicates
build_adder_user banner               # M16.81: ASCII-art big text
build_adder_user strings              # M16.81: print printable runs from a binary
