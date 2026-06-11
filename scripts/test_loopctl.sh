#!/usr/bin/env bash
# scripts/test_loopctl.sh — regression for the /dev/loop/ctl control
# file as a NAMESPACE-SERVED namec devtab cdev (DEV_LOOPCTL).
#
# Phase 4b retired FD_LOOP_MARK: /dev/loop/ctl is no longer a literal-
# path magic-fd bypass in fs/vfs.ad — `bind '#c' /dev` rewrites the
# open to `#c/loop/ctl`, _open_dev_leaf's namec devtab probe resolves
# it (_devtab_lookup -> DEV_LOOPCTL), and reads/writes dispatch through
# the FD_CHAN_MARK arm into loopctl_read / loopctl_write. This script
# proves that whole fd path with the REAL userland tool (user/losetup.ad)
# — scripts/test_loop.sh only exercises the kernel-internal loop_attach
# data path, never the ctl FILE.
#
# Pipeline (same shape as test_devproc.sh):
#   1. Build userland (hamsh + losetup).
#   2. Plant /init = hamsh + the FAT image fixture /tests/loop/disk.img
#      (ENABLE_LOOP_TEST=1 also plants /etc/loop-test, so the boot
#      self-test attaches loop0 — giving `losetup -a` a deterministic
#      first row).
#   3. Rebuild the kernel image.
#   4. Boot QEMU and drive losetup via hamsh, prompt-gated:
#        bind '#c' /dev                          (rc.boot's device bind)
#        losetup -a                              read  /dev/loop/ctl
#        losetup /dev/loop1 /tests/loop/disk.img write /dev/loop/ctl
#        losetup -a                              re-read shows loop1
#
# Also covers the DEV_BLK pool-chan fd path (Phase 4b retired
# FD_BLK_MARK): `bind '#b' /dev/blk` + `cat /dev/blk/loop0/size` opens
# the size leaf through devblk_leaf_match -> _open_blk_marked ->
# namec_open_blk_file (the 64-bit (mode<<32)|slot pack rides the chan's
# back_ptr) and reads through namec_read's DEV_BLK dispatch into
# devblk_read. The fixture is 64 sectors, so the answer is exactly
# 32768.
#
# PASS criteria:
#   - "loop0 <nbytes>" listed (read path through DEV_LOOPCTL)
#   - "/dev/loop1: /tests/loop/disk.img" (attach verb accepted)
#   - "loop1 <nbytes>" listed after the attach (write took effect)
#   - "32768" from cat /dev/blk/loop0/size (DEV_BLK chan read path)
#   - POST_LOOPCTL_OK (hamsh responsive afterwards)
#   - NO "losetup: cannot open /dev/loop/ctl" line

. "$(dirname "$0")/_build_lock.sh"
. "$(dirname "$0")/_qemu_drive.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf

echo "[test_loopctl] (1/4) Build userland (hamsh + losetup)"
bash scripts/build_user.sh >/dev/null

echo "[test_loopctl] (2/4) Plant /init = hamsh + loop fixture in cpio"
INIT_ELF="$HAMSH_ELF" ENABLE_LOOP_TEST=1 \
    python3 scripts/build_initramfs.py >/dev/null

echo "[test_loopctl] (3/4) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

echo "[test_loopctl] (4/4) Boot QEMU + drive losetup via hamsh"
LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null' EXIT

# Namespace recipe: this boot plants hamsh directly as /init (no
# /etc/rc.boot), so the Pgrp starts with an EMPTY mount table. The
# `bind '#c' /dev` below is the same line rc.boot applies — losetup's
# open("/dev/loop/ctl") is then served through the real namespace
# machinery (chan_resolve_prefix -> _open_dev_leaf -> devtab probe).
set +e
qemu_drive "$LOG" "$ELF" "[hamsh] M16.35 shell ready" 130 \
    -- "bind '#c' /dev" 2 \
       "bind '#b' /dev/blk" 2 \
       "losetup -a" 4 \
       "losetup /dev/loop1 /tests/loop/disk.img" 4 \
       "losetup -a" 4 \
       "cat /dev/blk/loop0/size" 3 \
       "echo POST_LOOPCTL_OK" 3 \
       "exit" 1
rc="$QEMU_DRIVE_RC"
set -e

echo "[test_loopctl] --- captured output ---"
cat "$LOG"
echo "[test_loopctl] --- end output ---"

fail=0

if grep -a -F -q "losetup: cannot open /dev/loop/ctl" "$LOG"; then
    echo "[test_loopctl] MISS: losetup could not OPEN /dev/loop/ctl"
    fail=1
fi

# Read path: the boot self-test attached loop0; `losetup -a` must list it.
if grep -a -E -q "loop0 [0-9]+" "$LOG"; then
    echo "[test_loopctl] OK: losetup -a listed loop0 (ctl read path)"
else
    echo "[test_loopctl] MISS: loop0 row absent from losetup -a"
    fail=1
fi

# Write path: the attach verb must be accepted (losetup echoes the
# device + image on a successful ctl write)...
if grep -a -F -q "/dev/loop1: /tests/loop/disk.img" "$LOG"; then
    echo "[test_loopctl] OK: attach verb accepted (ctl write path)"
else
    echo "[test_loopctl] MISS: attach confirmation line absent"
    fail=1
fi

# ...and must have taken effect: the second listing shows loop1.
if grep -a -E -q "loop1 [0-9]+" "$LOG"; then
    echo "[test_loopctl] OK: loop1 listed after attach"
else
    echo "[test_loopctl] MISS: loop1 row absent after attach"
    fail=1
fi

# DEV_BLK chan read path: the 64-sector fixture's size leaf answers
# exactly 32768 (the boot self-test attached it as loop0).
if grep -a -E -q "^32768" "$LOG"; then
    echo "[test_loopctl] OK: /dev/blk/loop0/size read 32768 (DEV_BLK chan path)"
else
    echo "[test_loopctl] MISS: /dev/blk/loop0/size did not answer 32768"
    fail=1
fi

if grep -a -F -q "POST_LOOPCTL_OK" "$LOG"; then
    echo "[test_loopctl] OK: hamsh remains responsive"
else
    echo "[test_loopctl] MISS: hamsh died after the losetup round-trip"
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_loopctl] FAIL (qemu rc=$rc)"
    exit 1
fi

echo "[test_loopctl] PASS — /dev/loop/ctl opened, read, and written through the namespace-served DEV_LOOPCTL chan path by the real losetup tool"
