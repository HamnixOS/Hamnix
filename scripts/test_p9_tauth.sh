#!/usr/bin/env bash
# scripts/test_p9_tauth.sh - F10-4 (#457) regression.
#
# Plan 9 mount(srvfd, afd, ...) used to silently drop afd inside
# sys/src/9/port/syschan.ad::do_mount (read into `_ignored`), so every
# 9P attach carried uname="" — a future userland file server could not
# trust the caller's identity. This regression asserts that:
#
#   * afd == -1 keeps the legacy (no-auth) path, kernel logs
#     `[mount] uname= (afd=-1)` BEFORE running the 9P attach handshake.
#
#   * A verified /dev/auth fd (user/pass dance for user "live")
#     handed to mount() makes the kernel log `[mount] uname=live`.
#     That is the new behavior — the principal name carried in
#     AuthSlot.user_buf is plumbed into Tattach.
#
#   * A FRESH /dev/auth fd with NO user/pass exchange (unverified)
#     is REJECTED by mount() with -1; the userland fixture marker
#     `[p9_tauth] unverified afd rejected (expected)` lands.
#
# Pipeline mirrors scripts/test_authdev.sh (qemu_drive + bind '#c' /dev):
#   1. Build userland (hamsh + the test fixture).
#   2. Plant /init = hamsh in cpio so we land at a shell prompt
#      (etc/passwd + etc/shadow are baked into the initramfs by
#      build_initramfs.py, same seed test_authdev.sh uses).
#   3. Build the test fixture -> /bin/test_p9_tauth.
#   4. Rebuild the kernel image.
#   5. Boot QEMU under qemu_drive (waits for the hamsh prompt, then
#      sends commands gated on the boot marker, not fixed sleeps).
#   6. Grep the serial log for the kernel + userland markers.

. "$(dirname "$0")/_build_lock.sh"
. "$(dirname "$0")/_qemu_drive.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf
TEST_ELF=build/user/test_p9_tauth.elf

echo "[test_p9_tauth] (1/5) Build userland (hamsh + coreutils)"
bash scripts/build_user.sh >/dev/null

echo "[test_p9_tauth] (2/5) Build tests/test_p9_tauth.ad -> $TEST_ELF"
python3 -m compiler.adder compile \
    --target=x86_64-adder-user \
    tests/test_p9_tauth.ad \
    -o "$TEST_ELF" >/dev/null

echo "[test_p9_tauth] (3/5) Plant /init = hamsh + /bin/test_p9_tauth in cpio"
INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py >/dev/null

echo "[test_p9_tauth] (4/5) Rebuild kernel image"
mkdir -p build
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

echo "[test_p9_tauth] (5/5) Boot QEMU under qemu_drive"
LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null' EXIT

# qemu_drive waits for the hamsh banner before sending any input, and
# the FEEDER_SYNC handshake proves the first-line drop has passed
# before we send the test cmd. `bind '#c' /dev` binds the devtab so
# /dev/auth is visible. /bin/test_p9_tauth then drives the fixture.
set +e
qemu_drive "$LOG" "$ELF" "[hamsh] M16.35 shell ready" 90 \
    -- "bind '#c' /dev" 2 \
       "/bin/test_p9_tauth" 6 \
       "exit" 2
rc="$QEMU_DRIVE_RC"
set -e

echo "[test_p9_tauth] --- captured output ---"
cat "$LOG"
echo "[test_p9_tauth] --- end output ---"

fail=0

if grep -a -F -q "[p9_tauth] start" "$LOG"; then
    echo "[test_p9_tauth] OK: fixture ran"
else
    echo "[test_p9_tauth] MISS: fixture banner missing"
    fail=1
fi

if grep -a -F -q "[mount] uname= (afd=-1)" "$LOG"; then
    echo "[test_p9_tauth] OK: legacy afd=-1 marker fired"
else
    echo "[test_p9_tauth] MISS: legacy afd=-1 marker absent"
    fail=1
fi

if grep -a -F -q "[mount] uname=live" "$LOG"; then
    echo "[test_p9_tauth] OK: verified afd marker fired with principal name"
else
    echo "[test_p9_tauth] MISS: '[mount] uname=live' absent (afd dropped or wrong name)"
    fail=1
fi

if grep -a -F -q "[p9_tauth] unverified afd rejected (expected)" "$LOG"; then
    echo "[test_p9_tauth] OK: unverified afd was rejected"
else
    echo "[test_p9_tauth] MISS: unverified afd was not rejected"
    fail=1
fi

if grep -a -F -q "[p9_tauth] PASS" "$LOG"; then
    echo "[test_p9_tauth] OK: fixture reached PASS"
else
    echo "[test_p9_tauth] MISS: PASS line absent"
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_p9_tauth] FAIL (qemu rc=$rc)"
    exit 1
fi

echo "[test_p9_tauth] PASS — afd is no longer silently dropped; verified principal name plumbed into Tattach uname"
