#!/usr/bin/env bash
# scripts/test_authdev.sh — regression for the /dev/auth credential cdev
# as a POOL-CHAN-backed fd (DEV_AUTH).
#
# Phase 4b retired FD_AUTH_MARK: an open of /dev/auth now allocates an
# AuthSlot (devauth_alloc) wrapped in a DEV_AUTH pool chan
# (namec_open_auth_file), and every fd op routes through the unified
# FD_CHAN_MARK arms:
#   * write "user <name>\n" / "pass <plain>\n" -> namec_write -> devauth_write
#   * read  "ok <uid> <gid>\n" or "denied\n"   -> namec_read  -> devauth_read
#   * SYS_SETUID_AUTH(fd) -> vfs_fd_auth_slot resolves the chan's
#     back_slot (the verified AuthSlot) for the identity change
#   * close -> namec_close's DEV_AUTH release arm -> devauth_close
#     (last-ref only — a fork/dup'd auth fd no longer yanks the slot on
#     the FIRST close, and task exit no longer leaks the slot)
#
# This is the LIGHT in-VM auth gate: a plain cpio boot with hamsh as
# /init, driving the REAL user/su.ad tool against the cpio-seeded
# hostowner (`live`, password "hamnix" — etc/passwd + etc/shadow ship in
# the initramfs). The heavyweight installed-system flow (useradd ->
# passwd -> su on the live ext4 shadow) stays in scripts/test_auth.sh.
#
# Pipeline (same shape as test_devproc.sh):
#   1. Build userland (hamsh + su + newshell builtin).
#   2. Plant /init = hamsh (default cpio: etc/passwd + etc/shadow seed).
#   3. Rebuild the kernel image.
#   4. Boot QEMU and drive, prompt-gated:
#        bind '#c' /dev            (rc.boot's device bind)
#        newshell nosuchuser       cheap negative control (passwd lookup)
#        su live + WRONG password  /dev/auth verdict "denied"
#        su live + RIGHT password  /dev/auth verdict "ok" +
#                                  SYS_SETUID_AUTH on the verified fd
#
# PASS criteria:
#   - "newshell: no such user"            (unknown user rejected)
#   - "su: Authentication failure"        (wrong password denied)
#   - "su: switched to uid 1 (live)"      (right password verified AND
#                                          SYS_SETUID_AUTH resolved the
#                                          DEV_AUTH chan's slot)
#   - POST_AUTHDEV_OK                     (nested shell responsive)
#   - NO "su: cannot open /dev/auth" and NO "su: identity change failed"

. "$(dirname "$0")/_build_lock.sh"
. "$(dirname "$0")/_qemu_drive.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf

echo "[test_authdev] (1/4) Build userland (hamsh + su)"
bash scripts/build_user.sh >/dev/null

echo "[test_authdev] (2/4) Plant /init = hamsh in cpio"
INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py >/dev/null

echo "[test_authdev] (3/4) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

echo "[test_authdev] (4/4) Boot QEMU + drive su via hamsh"
LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null' EXIT

# Namespace recipe: hamsh-as-init starts with an EMPTY mount table; the
# `bind '#c' /dev` below is the same line rc.boot applies, so su's
# open("/dev/auth") is served through the real namespace machinery.
#
# su reads the password with echo SUPPRESSED (raw byte loop) — feed the
# password as the NEXT line with a generous settle so su is fully up
# and blocked in its read() before the bytes land (same pacing as
# scripts/test_auth.sh).
set +e
qemu_drive "$LOG" "$ELF" "[hamsh] M16.35 shell ready" 150 \
    -- "bind '#c' /dev" 2 \
       "newshell nosuchuser" 3 \
       "su live" 4 \
       "totally-wrong" 6 \
       "su live" 4 \
       "hamnix" 8 \
       "echo POST_AUTHDEV_OK" 3 \
       "exit" 2 \
       "exit" 1
rc="$QEMU_DRIVE_RC"
set -e

echo "[test_authdev] --- captured output ---"
cat "$LOG"
echo "[test_authdev] --- end output ---"

fail=0

if grep -a -F -q "su: cannot open /dev/auth" "$LOG"; then
    echo "[test_authdev] MISS: su could not OPEN /dev/auth"
    fail=1
fi
if grep -a -F -q "su: identity change failed" "$LOG"; then
    echo "[test_authdev] MISS: SYS_SETUID_AUTH rejected the verified fd"
    fail=1
fi

if grep -a -F -q "newshell: no such user" "$LOG"; then
    echo "[test_authdev] OK: unknown user rejected (passwd lookup)"
else
    echo "[test_authdev] MISS: 'newshell: no such user' absent"
    fail=1
fi

if grep -a -F -q "su: Authentication failure" "$LOG"; then
    echo "[test_authdev] OK: wrong password denied through /dev/auth"
else
    echo "[test_authdev] MISS: wrong-password su was not denied"
    fail=1
fi

if grep -a -F -q "su: switched to uid 1 (live)" "$LOG"; then
    echo "[test_authdev] OK: right password verified + SYS_SETUID_AUTH resolved the DEV_AUTH chan slot"
else
    echo "[test_authdev] MISS: 'su: switched to uid 1 (live)' absent"
    fail=1
fi

if grep -a -F -q "POST_AUTHDEV_OK" "$LOG"; then
    echo "[test_authdev] OK: nested shell responsive after su"
else
    echo "[test_authdev] MISS: nested shell unresponsive after su"
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_authdev] FAIL (qemu rc=$rc)"
    exit 1
fi

echo "[test_authdev] PASS — /dev/auth opened, written, read, and consumed by SYS_SETUID_AUTH through the DEV_AUTH pool-chan path by the real su tool"
