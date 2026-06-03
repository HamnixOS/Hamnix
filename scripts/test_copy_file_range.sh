#!/usr/bin/env bash
# scripts/test_copy_file_range.sh — linux-abi copy_file_range(2)/sendfile(2)
# fd->fd byte-copy self-test.
#
# Proves the Linux-ABI copy_file_range (syscall nr 326) and sendfile
# (nr 40) handlers in linux_abi/u_syscalls.ad copy bytes fd->fd through
# the real in-kernel dispatch entry (linux_u_syscall_dispatch) and the
# VFS read/write path — the exact route a Debian/glibc `cp` takes:
#
#   * copy_file_range: write 8 known bytes to a source tmpfs file, copy
#     the whole lot into a fresh dest file with NULL offset pointers,
#     read the dest back and assert byte-equality. Also asserts flags!=0
#     -> -EINVAL and a bad fd -> -EBADF.
#   * sendfile: copy 4 bytes from a source file at an explicit *offset=2
#     into a dest file, assert the count, that *offset advanced to 6, and
#     that the copied bytes match source[2..5].
#
# Mechanism (pure boot self-test, no userland interaction) — identical to
# scripts/test_uabi_fills.sh: the copy_file_range / sendfile blocks live
# inside uabi_fills_selftest() (linux_abi/u_syscalls.ad), gated by the
# /etc/uabi-fills-test marker that build_initramfs.py plants when
# ENABLE_UABI_FILLS_TEST=1. They print "[copyfilerange] PASS" and
# "[sendfile] PASS" on success.
#
# Pass marker:  [test_copy_file_range] PASS
# Fail marker:  [test_copy_file_range] FAIL

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf
BOOT_TIMEOUT="${CFR_BOOT_TIMEOUT:-120}"

echo "[test_copy_file_range] (1/3) Build userland (init)"
bash scripts/build_user.sh >/dev/null

echo "[test_copy_file_range] (2/3) Build kernel with /etc/uabi-fills-test marker"
INIT_ELF=build/user/init.elf ENABLE_UABI_FILLS_TEST=1 \
    python3 scripts/build_initramfs.py >/dev/null
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1 || true' EXIT

echo "[test_copy_file_range] (3/3) Boot QEMU and run the copy_file_range/sendfile self-test"
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

echo "[test_copy_file_range] --- self-test output ---"
grep -a -E "\[copyfilerange\]|\[sendfile\]|\[UABI_FILLS\]" "$LOG" || true
echo "[test_copy_file_range] --- end ---"

fail=0

# rc=124 is the expected timeout kill (kernel halts without powering off
# qemu); rc=0 a clean shutdown. Anything else is a real QEMU failure.
if [ "$rc" -ne 0 ] && [ "$rc" -ne 124 ]; then
    echo "[test_copy_file_range] FAIL: qemu exited rc=$rc" >&2
    fail=1
fi

# An explicit internal failure is fatal.
if grep -a -qF "[UABI_FILLS] FAIL" "$LOG"; then
    echo "[test_copy_file_range] FAIL: kernel self-test reported an internal failure" >&2
    grep -a -F "[UABI_FILLS] FAIL" "$LOG" >&2 || true
    fail=1
fi

if ! grep -a -qF "[copyfilerange] PASS" "$LOG"; then
    echo "[test_copy_file_range] FAIL: '[copyfilerange] PASS' not found in serial log." >&2
    fail=1
fi

if ! grep -a -qF "[sendfile] PASS" "$LOG"; then
    echo "[test_copy_file_range] FAIL: '[sendfile] PASS' not found in serial log." >&2
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_copy_file_range] FAIL"
    exit 1
fi

echo "[test_copy_file_range] PASS — copy_file_range(326) + sendfile(40) fd->fd copy through real dispatch + VFS read/write"
