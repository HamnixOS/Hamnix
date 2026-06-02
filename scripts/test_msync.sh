#!/usr/bin/env bash
# scripts/test_msync.sh — linux-abi msync(2): flush a dirtied MAP_SHARED
# writable file-backed mapping back to the BACKING FILE.
#
# The msync(2) Linux-ABI handler (_u_unimpl_msync in linux_abi/u_syscalls.ad)
# used to be a real -ENOSYS stub. This fixture proves the wired-up handler:
# it validates the addr is page-aligned and routes the flush through the
# kernel's mmap write-back primitive (mm/vma.ad::vma_writeback_range +
# fs/vfs.ad::vfs_pwrite_backing) — the same machinery the native SYS_MSYNC
# path uses — driven through the REAL in-kernel Linux-ABI dispatch (the
# exact path a Debian/glibc binary takes).
#
# Mechanism (pure boot self-test, no userland interaction):
#   1. scripts/build_initramfs.py honours ENABLE_MSYNC_TEST=1: it plants
#      /etc/msync-test (the gate marker).
#   2. init/main.ad at boot:37.msy detects the marker and runs
#      msync_selftest() (linux_abi/u_syscalls.ad): it creates a
#      known-content file on tmpfs (a WRITABLE backend — the cpio
#      initramfs is read-only and a MAP_SHARED-writable mapping over it is
#      refused), builds a shared-writable file VMA via
#      vma_alloc_file_shared, faults pages in, MODIFIES bytes through the
#      mapping, calls msync(addr,len,MS_SYNC) via the real dispatch, then:
#        * reads the backing file back via tmpfs_read (NOT the mapping)
#          and confirms the modified bytes landed in the FILE,
#        * confirms unmodified regions are preserved,
#        * asserts a non-page-aligned addr returns -EINVAL,
#        * asserts a zero-length range is a benign 0.
#   3. We boot the kernel (the _build_lock.sh qemu shim wraps the 64-bit
#      ELF in a BIOS GRUB ISO automatically — a raw `qemu -kernel` of the
#      higher-half ELF always fails on this host) and grep the serial log
#      for `[MSYNC] PASS`.
#
# Default boots ship NO /etc/msync-test file, so the self-test is a no-op
# skip everywhere else.
#
# Pass marker:  [test_msync] PASS
# Fail marker:  [test_msync] FAIL

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf
BOOT_TIMEOUT="${MSYNC_BOOT_TIMEOUT:-120}"

echo "[test_msync] (1/3) Build userland (init)"
bash scripts/build_user.sh >/dev/null

echo "[test_msync] (2/3) Build kernel with /etc/msync-test marker"
INIT_ELF=build/user/init.elf ENABLE_MSYNC_TEST=1 \
    python3 scripts/build_initramfs.py >/dev/null
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1 || true' EXIT

echo "[test_msync] (3/3) Boot QEMU and run the msync self-test"
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

echo "[test_msync] --- msync self-test output ---"
grep -a -E "\[MSYNC\]|\[boot:37.msy\]" "$LOG" || true
echo "[test_msync] --- end ---"

fail=0

# rc=124 is the expected timeout kill (kernel halts without powering off
# qemu); rc=0 a clean shutdown. Anything else is a real QEMU failure.
if [ "$rc" -ne 0 ] && [ "$rc" -ne 124 ]; then
    echo "[test_msync] FAIL: qemu exited rc=$rc" >&2
    fail=1
fi

# An explicit internal failure is fatal.
if grep -a -qF "[MSYNC] FAIL" "$LOG"; then
    echo "[test_msync] FAIL: kernel self-test reported an internal failure" >&2
    grep -a -F "[MSYNC] FAIL" "$LOG" >&2 || true
    fail=1
fi

if ! grep -a -qF "[MSYNC] PASS" "$LOG"; then
    echo "[test_msync] FAIL: '[MSYNC] PASS' not found in serial log." >&2
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_msync] FAIL"
    exit 1
fi

echo "[test_msync] PASS — msync flushes MAP_SHARED file pages to the backing file"
