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
    # Source lives in user/<name>.ad normally; a regression-test fixture
    # (e.g. test_hugepage) lives in tests/<name>.ad. Prefer user/, fall
    # back to tests/ so a test program can be registered here too.
    local src="user/${name}.ad"
    if [ ! -f "$src" ] && [ -f "tests/${name}.ad" ]; then
        src="tests/${name}.ad"
    fi
    echo "[build_user] compiling ${src} -> build/user/${name}.elf"
    python3 -m compiler.adder compile \
        --target=x86_64-adder-user \
        "$src" \
        -o "build/user/${name}.elf"
    file "build/user/${name}.elf"
}

build_adder_user init                 # PID 1 shim: execs /bin/hamsh with boot rc /etc/rc.boot
build_adder_user hamsh                # M16.35: interactive shell
build_adder_user ps                   # M16.36: dumps /proc snapshots
build_adder_user echo                 # M16.37: writes argv to stdout
build_adder_user cat                  # M16.37: streams files to stdout
build_adder_user aplay                # native HDA: streams a PCM/WAV file to /dev/audio
build_adder_user dup_demo             # M16.41: exercises sys_dup / sys_dup2
build_adder_user ls                   # M16.46: directory listing
build_adder_user lsblk                # enumerate /dev/blk devices + sizes (pre-install disk check)
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
build_adder_user uniq                 # collapse adjacent dup lines (-c/-d/-u)
build_adder_user nl                   # number stdin lines (-ba/-bt)
build_adder_user tac                  # cat in reverse line order
build_adder_user fold                 # wrap lines to width (-w N)
build_adder_user cksum                # POSIX CRC32 + byte count of stdin
build_adder_user rm                   # M16.65: tmpfs unlink
build_adder_user touch                # M16.65: create-empty / truncate
build_adder_user mkdir                # M16.65: no-op stub (flat tmpfs)
build_adder_user basename             # M16.66: strip path prefix
build_adder_user dirname              # M16.66: keep path prefix
build_adder_user cut                  # M16.66: -c column / range slice
build_adder_user paste                # merge lines of files (-d DELIM, -s serial)
build_adder_user comm                 # compare two SORTED files (3-col, -1/-2/-3)
build_adder_user split                # split a file into pieces (-l lines / -b bytes)
build_adder_user realpath             # canonicalise a path to absolute form
build_adder_user truncate             # set a file's size (-s SIZE, K/M suffix)
build_adder_user stat                 # file/inode status: name/size/type (-c %n/%s/%F)
build_adder_user nproc                # online CPU count from /proc/cpuinfo cpus_online
build_adder_user printenv             # print env (argv NAME=VALUE convention) or a named value
build_adder_user tty                  # print stdin terminal name (/dev/cons) via /fd/0 kind
build_adder_user mktemp               # create unique temp file/dir (-d) from a TEMPLATE
build_adder_user join                 # relational join of two SORTED files (-1/-2 field, -t sep)
build_adder_user expand               # convert tabs to spaces honoring column (-t N)
build_adder_user unexpand             # leading-blank runs to tabs (-a all, -t N)
build_adder_user shuf                 # random permutation of lines (-n N, -i LO-HI, -e ARGS)
build_adder_user factor               # prime factorization of integers (argv or stdin)
build_adder_user csplit               # split FILE into sections on PATTERNs (xx00, xx01, ...)
build_adder_user numfmt               # convert numbers to/from human-readable forms
build_adder_user pr                   # paginate text for printing (header + columns)
build_adder_user tsort                # topological sort of whitespace-separated token pairs
build_adder_user dircolors            # emit shell command setting LS_COLORS
build_adder_user tr                   # M16.66: SRC->DST byte translate
build_adder_user od                   # M16.66: -An -tx1 hex dump
build_adder_user printf               # M16.66: %s/%d + \n/\t/\\ escapes
build_adder_user cp                   # M16.66: SRC->DST file copy (<=8 KiB)
build_adder_user whoami               # current uid -> name via /etc/passwd
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
build_adder_user service              # native service mgmt: service <name> start|stop|restart|status|enable|disable
build_adder_user initctl              # native runlevel control: initctl <N> (telinit alias) via SYS_SVC_CTL
build_adder_user halt                 # M16.82: graceful exit / future ACPI halt
build_adder_user poweroff             # M16.82: same as halt for now
build_adder_user reboot               # M16.82: future i8042 0xFE pulse
build_adder_user insmod               # L1: load stock Linux 6.12 .ko
build_adder_user modprobe             # L1: resolve modules.dep + load deps
build_adder_user rmmod                # L1: unload by slot id
build_adder_user pgrep                # /proc/tasks comm-substring -> PIDs
build_adder_user kill                 # sys_kill(pid, sig); -SIG flag
build_adder_user sed                  # single s/A/B/ replace per line
build_adder_user vi                   # modal full-screen editor (NORMAL/INSERT/ex)
build_adder_user hamfm                # TUI file manager (navigate dirs, view files)
build_adder_user column               # format text into columns (fill / -t table / -s sep / -c width)
build_adder_user hxd                  # TUI hex+ASCII file viewer (xxd/hexdump -C, scrollable)
build_adder_user tree                 # recursive directory lister with box-drawing connectors
build_adder_user hdu                  # ncdu-style interactive disk-usage browser (recursive sizes, bar, navigate)
build_adder_user hlog                 # TUI kernel-log viewer/follower (dmesg -w / journalctl -f) over /proc/kmsg
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
build_adder_user crond                # cron daemon: /var/cron/crontab, minute-edge scheduler
build_adder_user crontab              # cron CLI: install FILE / -l list / -r remove
build_adder_user whatis               # M16.86: one-line description table
build_adder_user man                  # discovery: read /usr/share/man/<topic>.<N>.md
build_adder_user help                 # discovery: man-page index + `help <topic>` sugar
build_adder_user hamUI                # hamUI Phase 2: multi-window CLI (new/list/close)
build_adder_user hamUId               # hamUI Phase 4b: userland renderer (render <wid> -> AI-readable dump)
build_adder_user hamui_demo           # GTK/Qt-style toolkit (lib/hamui.ad) demo: label/button/entry/check/list
build_adder_user ham2048              # 2048 game on the hamui toolkit (lib/hamui.ad)
build_adder_user hamsnake             # Snake game on the hamui toolkit (lib/hamui.ad)
build_adder_user hamterm              # hamui GUI terminal: runs commands via real hamsh + piped stdout
build_adder_user hamedit              # hamui GUI text editor: open/save real files
build_adder_user hamfiles             # hamui GUI file browser: sys_listdir + launch hamedit
build_adder_user hamde                # hamui-based DE panel (Applications menu + clock + taskbar)
build_adder_user hamcalc              # integer calculator on the hamui toolkit (lib/hamui.ad)
build_adder_user hamclock             # clock + stopwatch on the hamui toolkit (lib/hamui.ad)
build_adder_user hamview              # image viewer (Eye-of-MATE equiv) on the hamui toolkit: decodes PPM(P6)/BMP, blits via an fb draw-layer
build_adder_user hamshot              # screenshot CLI (MATE-screenshot equiv): /dev/fb geometry + /dev/fbpix pixel stream -> P6 PPM (view with hamview)
build_adder_user hammon               # live system monitor (uptime/mem/process list) on the hamui toolkit (lib/hamui.ad) — reads /proc/uptime,/proc/meminfo,/proc/tasks
build_adder_user hamecho              # Increment-1 DE rewrite: first SEPARATE-PROCESS app; echoes routed keys (proves focus-gated input ownership)
build_adder_user top                  # M16.87: one-shot /proc dashboard
build_adder_user ifconfig             # M16.87: stub lo 127.0.0.1/8
build_adder_user ping                 # native Adder ping: Plan-9-shaped /net/icmp client
build_adder_user host                 # native Adder DNS resolver: forward (A) + reverse (PTR) via SYS_RESOLVE/SYS_RESOLVE_PTR
build_adder_user curl                 # native Adder HTTP/HTTPS fetch (body to stdout/-o FILE) over user/http9.ad
build_adder_user wget                 # native Adder HTTP/HTTPS fetch saved to a file over user/http9.ad
build_adder_user ntpd                 # native Adder NTP client: anchors rtc_boot_epoch via /net/udp
build_adder_user route                # M16.87: stub loopback routing row
build_adder_user lsmod                # M16.87: stub module table
build_adder_user dmesg                # M16.87: placeholder until kernel ring buf
build_adder_user su                   # switch user: /dev/auth verify + SYS_SETUID_AUTH
build_adder_user passwd               # set password via hostowner-gated /dev/auth setpass
build_adder_user useradd              # per-user home FILE SERVER on the shared ext4 root (docs/security.md)
build_adder_user login                # real login: /dev/auth verify + identity change + exec shell
build_adder_user getty                # M16.87: VT-aware getty: opens /dev/vt/N then exec /bin/hamsh
build_adder_user chvt                 # VT: switch active virtual terminal (writes to /dev/vt/ctl)
build_adder_user loadkeys             # task #178: select keyboard layout (writes a name to /dev/keymap)
build_adder_user hfw                  # native firewall control: list/add/flush rules + policy via /dev/firewall
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
build_adder_user httpd                # native concurrent web server (master: accept loop + per-conn worker spawn)
build_adder_user httpd_worker         # web server per-connection worker: vhost routing + static files + CGI
build_adder_user cgi_echo             # sample CGI script: echoes CGI env + request body (test fixture)
build_adder_user sshd                 # SSH-2.0 server daemon: curve25519-sha256 KEX + chacha20-poly1305 + hamsh shell
build_adder_user ssh                  # SSH-2.0 OUTBOUND client: ssh [user@]host [cmd] over /net (mirrors sshd's transport)
build_adder_user preempt_hog          # preemption test: syscall-free infinite CPU hog
build_adder_user preempt_demo         # preemption test: spawns the hog, proves the timer preempts it
build_adder_user nice_hi              # #151 CFS-lite: high-priority (nice -20) CPU hog
build_adder_user nice_lo              # #151 CFS-lite: low-priority  (nice +19) CPU hog
build_adder_user nice_demo            # #151 CFS-lite: spawns nice_hi + nice_lo, proves CPU-share ratio
build_adder_user test_hugepage        # §hugepage: 2 MiB MAP_HUGETLB mmap test (tests/test_hugepage.ad)
build_adder_user hpm                  # Hamnix package manager (docs/packages.md)
build_adder_user mkfs_ext4            # installer: format a /dev/blk/<dev> as ext4 (via /ctl)
build_adder_user mkfs_fat             # installer: format a /dev/blk/<dev> as FAT (via /ctl; stub)
build_adder_user hamnix_partition     # installer: GPT init + ESP + rootfs mkpart on /dev/blk/<dev>
build_adder_user dd_blk               # installer: sector-aligned /dev/blk/SRC -> /dev/blk/DST copy
build_adder_user install_file_to_slot # installer: copy one local file → target ext4 partition (via /ctl install_file verb)
build_adder_user install_rootfs_from_manifest  # installer: walk manifest, install_file_to_slot each (target_path source_path) pair
build_adder_user haminstall           # installer: one-shot on-target install (GPT+mkfs+ESP+rootfs) with live-root safety guard
build_adder_user install              # installer: interactive `install` (disk picker + confirm) + --auto; Debian-style hpm package root install
build_adder_user losetup              # attach/detach a file as a loop block device via /dev/loop/ctl
build_adder_user sqfs_to_blk          # installer: stream a file from an in-RAM squashfs -> block dev (no media read)
build_adder_user live_distro_up       # live medium: extract live-distro.ext4 from the in-RAM squashfs -> RAM blockdev, post #distro (#410)

# --- X11 server + client (user/x11/ subdirectory) -------------------
# The source lives in user/x11/<name>.ad but the ELF goes into
# build/user/<name>.elf so build_initramfs.py's *.elf glob picks it up
# and installs it at /bin/<name>.
build_adder_x11() {
    local name="$1"
    echo "[build_user] compiling user/x11/${name}.ad -> build/user/${name}.elf"
    python3 -m compiler.adder compile \
        --target=x86_64-adder-user \
        "user/x11/${name}.ad" \
        -o "build/user/${name}.elf"
    file "build/user/${name}.elf"
}

build_adder_x11 x11srv        # X11 core-protocol server: listens on :6000, renders into wsys fb layer
build_adder_x11 xfill         # X11 demo client: CreateWindow + CreateGC + PolyFillRectangle round-trip
build_adder_x11 x11test       # X11 self-test driver: spawns x11srv + xfill, asserts both PASS
build_adder_x11 xclient_demo  # Standalone X11 app client: purple/cyan fill, used by test_x11_app.sh
build_adder_x11 x11apptest    # X11 app-in-desktop test: spawns x11srv + xclient_demo, checks wsys flush

# --- Self-hosting milestone: Adder-in-Adder lexer --------------------
echo "[build_user] compiling adder/compiler/lex_selftest.ad -> build/user/lex_selftest.elf"
python3 -m compiler.adder compile \
    --target=x86_64-adder-user \
    adder/compiler/lex_selftest.ad \
    -o build/user/lex_selftest.elf
file build/user/lex_selftest.elf

# --- Self-hosting milestone: Adder-in-Adder parser -------------------
echo "[build_user] compiling adder/compiler/parse_selftest.ad -> build/user/parse_selftest.elf"
python3 -m compiler.adder compile \
    --target=x86_64-adder-user \
    adder/compiler/parse_selftest.ad \
    -o build/user/parse_selftest.elf
file build/user/parse_selftest.elf

# --- Self-hosting milestone: Adder-in-Adder codegen ------------------
echo "[build_user] compiling adder/compiler/codegen_selftest.ad -> build/user/codegen_selftest.elf"
python3 -m compiler.adder compile \
    --target=x86_64-adder-user \
    adder/compiler/codegen_selftest.ad \
    -o build/user/codegen_selftest.elf
file build/user/codegen_selftest.elf

# --- Self-hosting milestone: Adder-in-Adder ELF emit -----------------
# On-device tool that runs lexer.ad -> parser.ad -> codegen.ad ->
# elf_emit.ad and dumps a complete, loadable user ELF as hex (consumed by
# scripts/test_selfhost_elf.sh, which then EXECs the emitted ELF natively).
echo "[build_user] compiling adder/compiler/codegen_elf_selftest.ad -> build/user/codegen_elf_selftest.elf"
python3 -m compiler.adder compile \
    --target=x86_64-adder-user \
    adder/compiler/codegen_elf_selftest.ad \
    -o build/user/codegen_elf_selftest.elf
file build/user/codegen_elf_selftest.elf

# Companion on-device emitter that exercises the .bss + .data model: a
# zero-init array global (.bss, no file bytes) plus initialised string +
# scalar globals (.data). Consumed by scripts/test_selfhost_bss.sh, which
# EXECs the emitted ELF natively to prove the BSS model works on the CPU.
echo "[build_user] compiling adder/compiler/codegen_bss_selftest.ad -> build/user/codegen_bss_selftest.elf"
python3 -m compiler.adder compile \
    --target=x86_64-adder-user \
    adder/compiler/codegen_bss_selftest.ad \
    -o build/user/codegen_bss_selftest.elf
file build/user/codegen_bss_selftest.elf

# --- hamnix-ac: generalized on-device Adder compile driver -----------
# Same pipeline as codegen_elf_selftest, but reads the source to compile
# from a host-injected file (/src/input.ad) instead of a baked snippet.
# Consumed by scripts/hamnix-ac and scripts/test_hamnix_ac.sh.
echo "[build_user] compiling adder/compiler/codegen_ac_driver.ad -> build/user/codegen_ac_driver.elf"
python3 -m compiler.adder compile \
    --target=x86_64-adder-user \
    adder/compiler/codegen_ac_driver.ad \
    -o build/user/codegen_ac_driver.elf
file build/user/codegen_ac_driver.elf

# --- adder_cc: generic ON-BOX Adder compiler tool --------------------
# Same self-hosted pipeline as codegen_ac_driver, but takes the input +
# output paths from argv and WRITES the emitted ELF straight to a file
# on the local fs (no serial round-trip). This is the front-end `hpm`
# spawns to compile a SOURCE package on the box (#186). Staged at
# /bin/adder_cc.
echo "[build_user] compiling adder/compiler/adder_cc_driver.ad -> build/user/adder_cc.elf"
python3 -m compiler.adder compile \
    --target=x86_64-adder-user \
    adder/compiler/adder_cc_driver.ad \
    -o build/user/adder_cc.elf
file build/user/adder_cc.elf
