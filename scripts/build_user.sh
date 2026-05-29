#!/usr/bin/env bash
# scripts/build_user.sh - assemble + link userland binaries.
#
# Builds two kinds of user binary:
#   * a couple of hand-written .S programs (hello, stdin_demo) linked
#     with user/init.lds — elf32-i386 wrappers with 64-bit code inside.
#   * the Adder-compiled userland (init, hamsh, coreutils, daemons).
# The output ELFs are read by scripts/build_initramfs.py and embedded
# into the cpio archive; build/user/init.elf becomes the kernel's
# /init (a thin shim that execs /bin/hamsh with boot rc /etc/rc.boot).
#
# Run this whenever you touch a user/*.S / user/*.ad file or the
# linker script. scripts/build_initramfs.py is what gets called next.

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

build_adder_user init                 # PID 1 shim: execs /bin/hamsh with boot rc /etc/rc.boot
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
build_adder_user nsbindprobe          # HAMSH §18 stage-5: external-bind COW probe
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
build_adder_user date                 # /proc/realtime — RTC + TSC delta
build_adder_user more                 # M16.67: 24-line pager over stdin
build_adder_user find                 # M16.67: recursive listdir walk
build_adder_user diff                 # M16.67: byte-compare two files
build_adder_user motd  # M16.68: print /etc/motd
build_adder_user df                   # M16.70: dump /proc/mounts
build_adder_user du                   # M16.70: entry-count under path
build_adder_user tail                 # M16.70: last N lines of stdin
build_adder_user cmp                  # M16.70: byte-compare two files
build_adder_user which                # M16.74: PATH lookup tool
build_adder_user free                 # M16.74: /proc/meminfo as free table
build_adder_user uptime               # M16.74: /proc/uptime in seconds
build_adder_user mv                   # M16.74: copy + unlink (no rename(2))
build_adder_user ln                   # M16.74: placeholder for symlink/hardlink
build_adder_user cal                  # M16.74: hard-coded May 2026 month grid
build_adder_user expr                 # M16.74: A OP B for + - * /
build_adder_user test                 # M16.74: -z/-n/=/!= predicates
build_adder_user banner               # M16.81: ASCII-art big text
build_adder_user strings              # M16.81: print printable runs from a binary
build_adder_user halt                 # M16.82: graceful exit / future ACPI halt
build_adder_user poweroff             # M16.82: same as halt for now
build_adder_user reboot               # M16.82: future i8042 0xFE pulse
build_adder_user insmod               # L1: load stock Linux 6.12 .ko
build_adder_user modprobe             # L1: resolve modules.dep + load deps
build_adder_user rmmod                # L1: unload by slot id
build_adder_user pgrep                # /proc/tasks comm-substring -> PIDs
build_adder_user kill                 # sys_kill(pid, sig); -SIG flag
build_adder_user sed                  # single s/A/B/ replace per line
build_adder_user awk                  # literal {print $N} only
build_adder_user less                 # alias for more (24-line pager)
build_adder_user xargs                # stdin tokens -> sys_spawn argv
build_adder_user ascii                # printable ASCII 32..126 table
build_adder_user base64               # M16.86: RFC 4648 encode/decode
build_adder_user tar                  # native ustar (POSIX tar): -c/-x/-t -f ARCHIVE
build_adder_user gzip                 # native gzip: stored-block DEFLATE + .gz framing; -d via inflate
build_adder_user gunzip               # native gunzip: full INFLATE (stored/fixed/dynamic) via lib/zlib/inflate
build_adder_user md5sum               # M16.86: fixed-hash stub (real MD5 deferred)
build_adder_user env_show             # M16.86: hint about hamsh's `env` builtin
build_adder_user watch                # M16.86: -n N CMD, runs CMD twice w/ delay
build_adder_user whatis               # M16.86: one-line description table
build_adder_user man                  # discovery: read /usr/share/man/<topic>.<N>.md
build_adder_user help                 # discovery: man-page index + `help <topic>` sugar
build_adder_user hamUI                # hamUI Phase 2: multi-window CLI (new/list/close)
build_adder_user hamUId               # hamUI Phase 4b: userland renderer (render <wid> -> AI-readable dump)
build_adder_user top                  # M16.87: one-shot /proc dashboard
build_adder_user ifconfig             # M16.87: stub lo 127.0.0.1/8
build_adder_user ping                 # native Adder ping: Plan-9-shaped /net/icmp client
build_adder_user curl                 # native Adder HTTP/HTTPS fetch (body to stdout/-o FILE) over user/http9.ad
build_adder_user wget                 # native Adder HTTP/HTTPS fetch saved to a file over user/http9.ad
build_adder_user ntpd                 # native Adder NTP client: anchors rtc_boot_epoch via /net/udp
build_adder_user route                # M16.87: stub loopback routing row
build_adder_user lsmod                # M16.87: stub module table
build_adder_user dmesg                # M16.87: placeholder until kernel ring buf
build_adder_user su                   # M16.87: stub (single-user)
build_adder_user passwd               # M16.87: stub (no shadow file)
build_adder_user useradd              # per-user home FILE SERVER on the shared ext4 root (docs/security.md)
build_adder_user login                # M16.87: stub auth hint
build_adder_user getty                # M16.87: announces + exec /bin/hamsh
# distrorun RETIRED: the distro-shape namespace is no longer a bespoke
# launcher binary. /etc/rc.boot defines it as a captured `ns clean {}`
# value (`linux`, with a `debian` alias for the same body); a Linux
# binary is run with plain namespace verbs — `enter linux { ... }`.
# See HAMSH_SPEC §0/§11 and etc/rc.boot.
build_adder_user hamwd                # Phase D: Hamnix Window Daemon (Layer 3 / 9P file server skeleton)
build_adder_user p9srv_demo           # Phase D / V4: minimum-viable userspace 9P server (test fixture)
build_adder_user distrofs             # Plan 9 distro: userland 9P file-server daemon for the distro /var tree
build_adder_user nsrun                 # Plan 9 shim launcher: runs a program in a private distrofs-backed namespace
# apt/dpkg/dpkg_deb RETIRED — replaced by real Debian binaries run via
# `enter linux { /usr/bin/apt-get ... }` against the debootstrap'd tree
# staged at /var/lib/distros/default/ (HAMNIX_DEFAULT_REAL_DEBIAN=1).
# Per the user's direction: "apt should be a Linux binary running in a
# Linux namespace." See scripts/test_linux_apt_install.sh.
build_adder_user u_server             # U-socket V1: native TCP server (bind/listen/accept smoke test)
build_adder_user u_tlstest            # U-TLS: native HTTPS client (TLS over the /net file tree)
build_adder_user httpd                # U-socket: static-file HTTP/1.0 server daemon (/bin/httpd)
build_adder_user sshd                 # SSH-2.0 server daemon: curve25519-sha256 KEX + chacha20-poly1305 + hamsh shell
build_adder_user ssh                  # SSH-2.0 OUTBOUND client: ssh [user@]host [cmd] over /net (mirrors sshd's transport)
build_adder_user preempt_hog          # preemption test: syscall-free infinite CPU hog
build_adder_user preempt_demo         # preemption test: spawns the hog, proves the timer preempts it
build_adder_user hpm                  # Hamnix package manager (docs/packages.md)
build_adder_user mkfs_ext4            # installer: format a /dev/blk/<dev> as ext4 (via /ctl)
build_adder_user mkfs_fat             # installer: format a /dev/blk/<dev> as FAT (via /ctl; stub)
build_adder_user hamnix_partition     # installer: GPT init + ESP + rootfs mkpart on /dev/blk/<dev>
build_adder_user dd_blk               # installer: sector-aligned /dev/blk/SRC -> /dev/blk/DST copy
build_adder_user install_file_to_slot # installer: copy one local file → target ext4 partition (via /ctl install_file verb)
build_adder_user install_rootfs_from_manifest  # installer: walk manifest, install_file_to_slot each (target_path source_path) pair
