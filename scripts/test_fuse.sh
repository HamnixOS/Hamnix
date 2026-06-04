#!/usr/bin/env bash
# scripts/test_fuse.sh — /dev/fuse + FUSE wire-protocol READ round-trip.
#
# The Linux-ABI shim gains a REAL /dev/fuse char device plus the FUSE kernel
# wire protocol (linux_abi/u_fuse.ad, routed through the real VFS open/read/
# write/close dispatch in fs/vfs.ad). A userspace daemon opens /dev/fuse, runs
# the FUSE_INIT handshake, mounts a target prefix into its namespace, and
# serves a filesystem the kernel VFS reads through — sshfs / gocryptfs /
# ntfs-3g / squashfuse / AppImage all round-trip exactly this ABI. The mount
# attaches as a Plan-9 namespace file-server (a target prefix routes to the
# connection), NOT a global VFS patch.
#
# This fixture proves the full READ round-trip via a boot self-test (no
# userland interaction):
#
#   1. scripts/build_initramfs.py honours ENABLE_FUSE_TEST=1: it plants
#      /etc/fuse-test (the gate marker).
#   2. init/main.ad at boot:37.fuse detects the marker and runs fuse_selftest()
#      (linux_abi/u_fuse.ad), which:
#        * opens a /dev/fuse connection fd (FD_FUSE_CONN_MARK);
#        * runs the FUSE_INIT (opcode 26) handshake: the kernel enqueues a
#          fuse_in_header + fuse_init_in; the in-kernel daemon role reads it off
#          the cdev and writes a fuse_out_header + fuse_init_out (major=7);
#        * mounts the connection at /fuse (the namespace bind);
#        * VFS-opens /fuse/hello, driving FUSE_LOOKUP(1) + FUSE_GETATTR(3) +
#          FUSE_OPEN(14) as genuine header+body requests over the cdev;
#        * FUSE_READ(15)s the file and asserts the bytes == "FUSE-OK\n" (8
#          bytes), matched by `unique` through the fuse_in/fuse_out headers;
#        * FUSE_RELEASE(18)s and closes.
#   3. We boot the kernel (the _build_lock.sh qemu shim wraps the 64-bit ELF in
#      a BIOS GRUB ISO automatically) and grep the serial log for `[fuse] PASS`.
#
# No scratch disk is attached. Default boots ship NO /etc/fuse-test file, so
# the self-test is a no-op skip everywhere else.
#
# Pass marker:  [test_fuse] PASS   (kernel prints [fuse] PASS)
# Fail marker:  [test_fuse] FAIL

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf
BOOT_TIMEOUT="${FUSE_BOOT_TIMEOUT:-120}"

echo "[test_fuse] (1/3) Build userland (init)"
bash scripts/build_user.sh >/dev/null

echo "[test_fuse] (2/3) Build kernel with /etc/fuse-test marker"
INIT_ELF=build/user/init.elf ENABLE_FUSE_TEST=1 \
    python3 scripts/build_initramfs.py >/dev/null
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1 || true' EXIT

echo "[test_fuse] (3/3) Boot QEMU and run the fuse self-test"
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

echo "[test_fuse] --- fuse self-test output ---"
grep -a -E "\[FUSE\]|\[fuse\]|\[boot:37.fuse\]" "$LOG" || true
echo "[test_fuse] --- end ---"

fail=0

# rc=124 is the expected timeout kill (kernel halts without powering off
# qemu); rc=0 a clean shutdown. Anything else is a real QEMU failure.
if [ "$rc" -ne 0 ] && [ "$rc" -ne 124 ]; then
    echo "[test_fuse] FAIL: qemu exited rc=$rc" >&2
    fail=1
fi

# An explicit internal failure is fatal.
if grep -a -qF "[FUSE] FAIL" "$LOG"; then
    echo "[test_fuse] FAIL: kernel self-test reported an internal failure" >&2
    grep -a -F "[FUSE] FAIL" "$LOG" >&2 || true
    fail=1
fi

if ! grep -a -qF "[fuse] PASS" "$LOG"; then
    echo "[test_fuse] FAIL: '[fuse] PASS' not found in serial log." >&2
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_fuse] --- full log ---"
    cat "$LOG"
    echo "[test_fuse] FAIL"
    exit 1
fi

echo "[test_fuse] PASS — /dev/fuse + FUSE wire-protocol READ round-trip" \
     "(LOOKUP+GETATTR+OPEN+READ+RELEASE) through the real VFS + cdev (qemu rc=$rc)"
