#!/usr/bin/env bash
# scripts/test_tmpfs_link.sh — §links: tmpfs symlink + hard-link support.
#
# tmpfs (fs/tmpfs.ad) gains real, RAM-backed symlink and hard-link support,
# and the VFS (fs/vfs.ad) routes vfs_symlink / vfs_link to it (previously
# both returned -EROFS for tmpfs paths). This fixture proves the full
# contract via a boot self-test (no userland interaction):
#
#   1. scripts/build_initramfs.py honours ENABLE_TMPFS_LINK_TEST=1: it
#      plants /etc/tmpfs-link-test (the gate marker).
#   2. init/main.ad at boot:37.tln detects the marker and runs
#      tmpfs_link_selftest() (fs/vfs.ad):
#        * create a tmpfs file with known contents;
#        * create a tmpfs SYMLINK to it and verify opening the symlink
#          reads the file's contents (resolver follows the symlink on
#          open through _open_tmpfs_read);
#        * create tmpfs HARD LINKS and verify every name reads the same
#          data;
#        * unlink names one at a time and verify the surviving names still
#          read the data (per-slot link count), then that the last unlink
#          actually frees the entry.
#   3. We boot the kernel (the _build_lock.sh qemu shim wraps the 64-bit
#      ELF in a BIOS GRUB ISO automatically) and grep the serial log for
#      `[TMPFS_LINK] PASS`.
#
# Pure RAM (tmpfs) — no scratch disk is attached. Default boots ship NO
# /etc/tmpfs-link-test file, so the self-test is a no-op skip everywhere
# else.
#
# Pass marker:  [test_tmpfs_link] PASS   (kernel prints [TMPFS_LINK] PASS)
# Fail marker:  [test_tmpfs_link] FAIL

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf
BOOT_TIMEOUT="${TMPFS_LINK_BOOT_TIMEOUT:-120}"

echo "[test_tmpfs_link] (1/3) Build userland (init)"
bash scripts/build_user.sh >/dev/null

echo "[test_tmpfs_link] (2/3) Build kernel with /etc/tmpfs-link-test marker"
INIT_ELF=build/user/init.elf ENABLE_TMPFS_LINK_TEST=1 \
    python3 scripts/build_initramfs.py >/dev/null
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1 || true' EXIT

echo "[test_tmpfs_link] (3/3) Boot QEMU and run the tmpfs-link self-test"
set +e
timeout "${BOOT_TIMEOUT}s" qemu-system-x86_64 \
    -kernel "$ELF" \
    -smp 1 \
    -nographic \
    -no-reboot \
    -m 256M \
    -monitor none \
    -serial stdio \
    </dev/null > "$LOG" 2>&1
rc=$?
set -e

echo "[test_tmpfs_link] --- tmpfs-link self-test output ---"
grep -a -E "\[TMPFS_LINK\]|\[boot:37.tln\]" "$LOG" || true
echo "[test_tmpfs_link] --- end ---"

fail=0

# rc=124 is the expected timeout kill (kernel halts without powering off
# qemu); rc=0 a clean shutdown. Anything else is a real QEMU failure.
if [ "$rc" -ne 0 ] && [ "$rc" -ne 124 ]; then
    echo "[test_tmpfs_link] FAIL: qemu exited rc=$rc" >&2
    fail=1
fi

# An explicit internal failure is fatal.
if grep -a -qF "[TMPFS_LINK] FAIL" "$LOG"; then
    echo "[test_tmpfs_link] FAIL: kernel self-test reported an internal failure" >&2
    grep -a -F "[TMPFS_LINK] FAIL" "$LOG" >&2 || true
    fail=1
fi

if ! grep -a -qF "[TMPFS_LINK] PASS" "$LOG"; then
    echo "[test_tmpfs_link] FAIL: '[TMPFS_LINK] PASS' not found in serial log." >&2
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_tmpfs_link] --- full log ---"
    cat "$LOG"
    echo "[test_tmpfs_link] FAIL"
    exit 1
fi

echo "[test_tmpfs_link] PASS — tmpfs symlink-follow + hard-link link-count" \
     "verified on the live in-RAM tmpfs (qemu rc=$rc)"
