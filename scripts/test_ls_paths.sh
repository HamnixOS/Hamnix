#!/usr/bin/env bash
# scripts/test_ls_paths.sh — M16.x regression for vfs_listdir cpio
# routing.
#
# Before the fix, fresh-boot real-hardware testing saw `ls`, `ls /`,
# and `ls /etc` all fail with "listdir failed" because vfs_listdir
# only knew about /mnt (FAT) and /ext (ext4) — anything else fell
# through to -EINVAL. The fix mirrors vfs_open's _is_initramfs_dir
# dispatch into vfs_listdir.
#
# The fixture (tests/test_ls_paths.ad) exercises:
#   1. sys_listdir("/")               → > 0
#   2. sys_listdir("/etc")            → > 0
#   3. chdir(/etc); sys_listdir("/etc") → > 0
#   4. chdir(/etc); sys_listdir(".")   → > 0  (relative resolves via cwd)
#
# AND we drive hamsh directly with `ls /`, `ls /etc`, `cd /etc; ls`,
# `cd /etc; ls .` to confirm the end-to-end UX matches.
#
# Pipeline mirrors scripts/test_cd_validation.sh.

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf
TEST_ELF=build/user/test_ls_paths.elf

echo "[test_ls_paths] (1/5) Build userland (hamsh + coreutils + ls)"
bash scripts/build_user.sh >/dev/null
bash scripts/build_modules.sh >/dev/null

echo "[test_ls_paths] (2/5) Build tests/test_ls_paths.ad -> $TEST_ELF"
python3 -m compiler.adder compile \
    --target=x86_64-adder-user \
    tests/test_ls_paths.ad \
    -o "$TEST_ELF" >/dev/null

echo "[test_ls_paths] (3/5) Plant /init = hamsh + /bin/test_ls_paths in cpio"
INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py >/dev/null

echo "[test_ls_paths] (4/5) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

echo "[test_ls_paths] (5/5) Boot QEMU + drive ls via hamsh and the fixture"
LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null' EXIT

set +e
(
    sleep 3
    # Freshly-booted hamsh drops the FIRST serial command line (it never
    # echoes) — prime with a bare newline so the fixture line below is
    # the SECOND command and actually runs.
    printf '\n'
    sleep 1
    # Direct kernel-level fixture covers the listdir contract. Send it
    # twice in case the prime didn't land — the fixture is idempotent.
    printf '/bin/test_ls_paths\n'
    sleep 2
    printf '/bin/test_ls_paths\n'
    sleep 2
    # Then drive /bin/ls through hamsh to confirm the user-visible
    # behaviour (no "listdir failed" lines, and the per-Pgrp rc.boot
    # binds /srv /net /proc /dev enumerate in `ls /`).
    printf 'ls /\n'
    sleep 1
    printf 'ls /etc\n'
    sleep 1
    printf 'cd /etc\n'
    sleep 1
    printf 'ls\n'
    sleep 1
    printf 'ls .\n'
    sleep 1
    printf 'exit\n'
    sleep 2
) | timeout 35s qemu-system-x86_64 \
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

echo "[test_ls_paths] --- captured output ---"
cat "$LOG"
echo "[test_ls_paths] --- end output ---"

fail=0

# Fixture markers — direct kernel listdir contract.
for marker in \
    "[test_ls_paths] start" \
    "[test_ls_paths] PASS: listdir(/) ok" \
    "[test_ls_paths] PASS: listdir(/etc) ok" \
    "[test_ls_paths] PASS: listdir(/etc) after chdir ok" \
    "[test_ls_paths] PASS: listdir(.) resolves via cwd ok" \
    "[test_ls_paths] done"
do
    if grep -F -q "$marker" "$LOG"; then
        echo "[test_ls_paths] OK: '$marker'"
    else
        echo "[test_ls_paths] MISS: '$marker'"
        fail=1
    fi
done

# hamsh-level UX — `ls /` and `ls /etc` should produce entries.
# `motd` is in /etc; `etc` and `bin` are in /.
if grep -F -q "motd" "$LOG"; then
    echo "[test_ls_paths] OK: ls /etc found motd"
else
    echo "[test_ls_paths] MISS: ls /etc didn't list motd"
    fail=1
fi
if grep -F -q "etc" "$LOG"; then
    echo "[test_ls_paths] OK: ls / found etc"
else
    echo "[test_ls_paths] MISS: ls / didn't list etc"
    fail=1
fi

# Plan-9 union enumeration: the per-Pgrp bind points installed by
# /etc/rc.boot (`bind '#s' /srv`, `bind '#I' /net`, `bind '#p' /proc`,
# `bind '#c' /dev`) live in the namespace mtab, not on any backing FS.
# They MUST still enumerate as direct children of `/`. Before the
# _open_dir_with synthesis fallback fix, `ls /` dropped every one of
# them (only the cpio-backed names showed). Each name appears in the
# log ONLY via `ls /`, so a plain grep is a sound presence check.
for bm in srv net proc dev; do
    if grep -F -q -x "$bm" "$LOG"; then
        echo "[test_ls_paths] OK: ls / enumerates bind point '$bm'"
    else
        echo "[test_ls_paths] MISS: ls / missing bind point '$bm'"
        fail=1
    fi
done

# Negative check: no "listdir failed" should appear anywhere in the
# user-driven section.
if grep -F -q "ls: listdir failed" "$LOG"; then
    echo "[test_ls_paths] MISS: ls printed 'listdir failed' — regression!"
    fail=1
else
    echo "[test_ls_paths] OK: no 'listdir failed' in user ls output"
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_ls_paths] FAIL (qemu rc=$rc)"
    exit 1
fi
echo "[test_ls_paths] PASS"
