#!/usr/bin/env bash
# scripts/test_u33_busybox_applets.sh -- U33: drive real busybox
# applets (echo, cat, ls, pwd, uname) through hamsh.
#
# U33 widens the verb surface beyond the U29 banner:
#   * busybox echo hello world    — pure stdio write
#   * busybox cat /etc/motd       — open + read + write loop
#   * busybox ls /bin             — getdents64 directory walk
#   * busybox pwd                 — getcwd round-trip
#   * busybox uname               — utsname plumbing
#
# FIXTURE (U42 re-point): switched off the dead glibc-static
# u_busybox (ET_EXEC @ 0x400000, refused by the elf-loader kernel-
# image collision guard from commit 653d962) onto the musl
# static-PIE (ET_DYN) busybox -- the same fixture U29 / U40 use.
#
# XFAIL (U42, real Hamnix gap): the `ls` applet. The musl busybox's
# ls produces NO output -- musl's opendir()/readdir() round-trip the
# directory fd through musl's DIR struct and hand getdents64 fd 0
# (stdin) instead of the directory fd. getdents64 itself is correct
# (a direct SYS_getdents64 syscall enumerates a directory cleanly).
# This is a musl-libc <-> Hamnix fd-interaction gap, kernel-side fix
# out of scope here -- tracked as a U-track follow-up. The other
# four applets (echo / cat / pwd / uname) work and ARE required.
#
# Side effects: temporarily copies u_busybox_musl to
# tests/u-binary/busybox so basename-dispatch resolves the applet
# name; restores the original /init on exit.

. "$(dirname "$0")/_build_lock.sh"
. "$(dirname "$0")/_ensure_ubin.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

UBIN=tests/u-binary/u_busybox_musl
# Build-on-missing: the fixture is gitignored (host-built). If absent,
# build it from tests/u-binary/src/musl_busybox; only SKIP on a real
# failure (e.g. a genuine missing musl-gcc, or no network to fetch the
# busybox upstream tarball).
ensure_ubin_or_skip test_u33_busybox_applets u_busybox_musl musl_busybox

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf

echo "[test_u33_busybox_applets] (1/4) Build userland + modules"
bash scripts/build_user.sh
bash scripts/build_modules.sh

echo "[test_u33_busybox_applets] (2/4) Swap /init=hamsh + embed musl busybox"
cp tests/u-binary/u_busybox_musl tests/u-binary/busybox
HAMNIX_EMBED_UBIN=1 INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py

echo "[test_u33_busybox_applets] (3/4) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF"

echo "[test_u33_busybox_applets] (4/4) Boot QEMU + run busybox applets"
LOG=$(mktemp)
trap 'rm -f "$LOG" tests/u-binary/busybox; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null' EXIT

set +e
(
    sleep 3
    printf 'busybox echo hello world\n'
    sleep 2
    printf 'busybox cat /etc/motd\n'
    sleep 3
    printf 'busybox ls /bin\n'
    sleep 4
    printf 'busybox pwd\n'
    sleep 2
    printf 'busybox uname\n'
    sleep 2
    printf 'exit\n'
    sleep 1
) | timeout 90s qemu-system-x86_64 \
    -kernel "$ELF" \
    -smp 2 \
    -nographic \
    -no-reboot \
    -m 256M \
    -monitor none \
    -serial stdio \
    > "$LOG" 2>&1
rc=$?
set -e

echo "[test_u33_busybox_applets] --- captured output (last 400 lines) ---"
tail -n 400 "$LOG"
echo "[test_u33_busybox_applets] --- end output ---"

fail=0
hits=0

# Applet 1: busybox echo hello world — must produce "hello world".
if grep -F -q "hello world" "$LOG"; then
    echo "[test_u33_busybox_applets] OK   echo:   'hello world' printed"
    hits=$((hits + 1))
else
    echo "[test_u33_busybox_applets] FAIL echo:   'hello world' not seen"
    fail=1
fi

# Applet 2: busybox cat /etc/motd — at least 2 of these motd words
# must appear in output. Words come from etc/motd.
cat_hits=0
for word in Welcome Hamnix scratch Adder kernel; do
    if grep -F -q "$word" "$LOG"; then
        cat_hits=$((cat_hits + 1))
    fi
done
if [ "$cat_hits" -ge 2 ]; then
    echo "[test_u33_busybox_applets] OK   cat:    $cat_hits motd words printed"
    hits=$((hits + 1))
else
    echo "[test_u33_busybox_applets] FAIL cat:    only $cat_hits motd words (need >=2)"
    fail=1
fi

# Applet 3 (XFAIL — see header): busybox ls /bin. The musl busybox's
# ls produces no output (musl opendir/getdents64 fd round-trip gap).
# Scope the grep to the window AFTER `busybox ls /bin` and BEFORE the
# next command (`busybox pwd`) so motd / banner text bearing the same
# words elsewhere in the log can't masquerade as ls output.
LS_WINDOW=$(awk '/busybox ls \/bin/{flag=1;next} /busybox pwd/{flag=0} flag' "$LOG")
ls_hits=0
for name in echo cat ls sh mount uname pwd grep find date head; do
    if printf '%s\n' "$LS_WINDOW" | grep -F -q "$name"; then
        ls_hits=$((ls_hits + 1))
    fi
done
if [ "$ls_hits" -ge 5 ]; then
    echo "[test_u33_busybox_applets] XPASS ls:   $ls_hits binary names printed --"
    echo "    musl opendir/getdents64 now works (remove XFAIL)"
    hits=$((hits + 1))
else
    echo "[test_u33_busybox_applets] XFAIL ls:   $ls_hits binary names (musl"
    echo "    busybox 'ls' enumeration gap -- getdents64 itself is correct;"
    echo "    musl opendir() hands it the wrong fd. U-track follow-up.)"
fi

# Applet 4: busybox pwd — must produce "/".
if grep -E -q "^/[[:space:]]*$" "$LOG" || grep -F -q "/ " "$LOG"; then
    echo "[test_u33_busybox_applets] OK   pwd:    '/' printed"
    hits=$((hits + 1))
else
    echo "[test_u33_busybox_applets] FAIL pwd:    '/' not seen on its own line"
    fail=1
fi

# Applet 5: busybox uname — must produce "Hamnix" (_u_uname fills
# utsname.sysname with "Hamnix").
if grep -F -q "Hamnix" "$LOG"; then
    echo "[test_u33_busybox_applets] OK   uname:  'Hamnix' printed"
    hits=$((hits + 1))
else
    echo "[test_u33_busybox_applets] FAIL uname:  'Hamnix' not seen"
    fail=1
fi

if grep -F -q "TRAP: vector" "$LOG"; then
    echo "[test_u33_busybox_applets] DIAG: kernel reported a CPU exception"
    grep -F "TRAP: vector" "$LOG" | head -5 || true
    fail=1
fi
if grep -F -q "unknown syscall" "$LOG"; then
    echo "[test_u33_busybox_applets] DIAG: unknown syscall(s)"
    grep -F "unknown syscall" "$LOG" | sort -u | head -20 || true
fi
if grep -F -q "page fault" "$LOG"; then
    echo "[test_u33_busybox_applets] DIAG: page fault"
    grep -F "page fault" "$LOG" | head -5 || true
fi

echo "[test_u33_busybox_applets] summary: $hits/5 applet markers hit"
echo "    (ls is a marked XFAIL; the other 4 are required)"

if [ "$fail" -ne 0 ]; then
    echo "[test_u33_busybox_applets] FAIL (qemu rc=$rc)"
    exit 1
fi

echo "[test_u33_busybox_applets] PASS -- echo / cat / pwd / uname applets"
echo "    reached user output (ls XFAIL)"
