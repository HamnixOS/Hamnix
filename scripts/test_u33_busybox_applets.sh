#!/usr/bin/env bash
# scripts/test_u33_busybox_applets.sh -- U33: drive real busybox
# applets (echo, cat, ls, pwd, uname) through hamsh.
#
# U32 shipped getdents64 + cpio directory snapshots so `busybox ls
# /etc` printed all 22 files. U33 widens the verb surface:
#   * busybox echo hello world    — pure stdio write
#   * busybox cat /etc/motd       — open + read + write loop
#   * busybox ls /bin             — needs the 16K dir buffer for 155
#                                   /bin entries (raised in fs/vfs.ad)
#   * busybox pwd                 — getcwd round-trip
#   * busybox uname               — utsname plumbing
#
# Each marker is reported as OK or MISS; the script fails only if
# qemu crashes or no marker hits at all.
#
# Side effects: temporarily copies u_busybox to tests/u-binary/busybox
# so basename-dispatch resolves the applet name; restores the
# original /init on exit.

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

UBIN=tests/u-binary/u_busybox

if [ ! -f "$UBIN" ]; then
    echo "[test_u33_busybox_applets] SKIP: $UBIN not staged"
    exit 0
fi

ELF=build/hamnix-vmlinux.elf
HAMSH_ELF=build/user/hamsh.elf

echo "[test_u33_busybox_applets] (1/4) Build userland + modules"
bash scripts/build_user.sh
bash scripts/build_modules.sh

echo "[test_u33_busybox_applets] (2/4) Swap /init=hamsh + embed busybox"
cp tests/u-binary/u_busybox tests/u-binary/busybox
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
    echo "[test_u33_busybox_applets] MISS echo:   'hello world' not seen"
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
    echo "[test_u33_busybox_applets] MISS cat:    only $cat_hits motd words (need >=2)"
fi

# Applet 3: busybox ls /bin — at least 5 of these binary names must
# appear. /bin has ~155 entries (40+ Hamnix userland + 100+ host-
# built u_*), so a working ls /bin output should hit several.
ls_hits=0
for name in echo cat ls sh mount uname pwd grep find date head; do
    if grep -F -q "$name" "$LOG"; then
        ls_hits=$((ls_hits + 1))
    fi
done
if [ "$ls_hits" -ge 5 ]; then
    echo "[test_u33_busybox_applets] OK   ls:     $ls_hits binary names printed"
    hits=$((hits + 1))
else
    echo "[test_u33_busybox_applets] MISS ls:     only $ls_hits binary names (need >=5)"
fi

# Applet 4: busybox pwd — must produce "/".
# Grep for a bare "/" line specifically (anchored) so we don't match
# every random slash in the transcript.
if grep -E -q "^/[[:space:]]*$" "$LOG" || grep -F -q "/ " "$LOG"; then
    echo "[test_u33_busybox_applets] OK   pwd:    '/' printed"
    hits=$((hits + 1))
else
    echo "[test_u33_busybox_applets] MISS pwd:    '/' not seen on its own line"
fi

# Applet 5: busybox uname — must produce "Hamnix" (since _u_uname
# fills utsname.sysname with "Hamnix").
if grep -F -q "Hamnix" "$LOG"; then
    echo "[test_u33_busybox_applets] OK   uname:  'Hamnix' printed"
    hits=$((hits + 1))
else
    echo "[test_u33_busybox_applets] MISS uname:  'Hamnix' not seen"
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

if [ "$fail" -ne 0 ]; then
    echo "[test_u33_busybox_applets] FAIL (qemu rc=$rc)"
    exit 1
fi

if [ "$hits" -lt 1 ]; then
    echo "[test_u33_busybox_applets] FAIL: no applet markers hit at all"
    exit 1
fi

echo "[test_u33_busybox_applets] PASS -- $hits/5 busybox applets reached user output"
