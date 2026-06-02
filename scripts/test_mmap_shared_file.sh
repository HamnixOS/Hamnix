#!/usr/bin/env bash
# scripts/test_mmap_shared_file.sh — §shared-mmap: MAP_SHARED writable
# file-backed mmap with REAL write-back to the backing file.
#
# The native SYS_MMAP handler (arch/x86/kernel/syscall.ad) used to reject
# a MAP_SHARED *writable* file-backed mmap with -ENOSYS ("no writeback
# path yet"). This fixture proves the new is_file_shared VMA path: a
# writable file mapping whose dirtied pages are flushed to the backing
# FILE on msync(MS_SYNC) / munmap (mm/vma.ad::vma_writeback_range +
# fs/vfs.ad::vfs_pwrite_backing).
#
# Mechanism (pure boot self-test, no userland interaction):
#   1. scripts/build_initramfs.py honours ENABLE_MMAP_SHARED_TEST=1: it
#      plants /etc/mmap-shared-test (the gate marker).
#   2. init/main.ad at boot:37.mms detects the marker and runs
#      mmap_shared_selftest(): it creates a known-content file on tmpfs
#      (a WRITABLE backend — the cpio initramfs is read-only and a
#      MAP_SHARED-writable mapping over it is refused), builds a
#      shared-writable file VMA via vma_alloc_file_shared, faults pages
#      in, MODIFIES bytes through the mapping, msync(MS_SYNC)s
#      (vma_writeback_range), then:
#        * reads the backing file back via tmpfs_read (NOT the mapping)
#          and confirms the modified bytes landed in the FILE,
#        * confirms unmodified regions are preserved,
#        * builds a SECOND fresh mapping of the same file and confirms it
#          faults in the NEW (written-back) bytes.
#   3. We boot the kernel (the _build_lock.sh qemu shim wraps the 64-bit
#      ELF in a BIOS GRUB ISO automatically) and grep the serial log for
#      `[mmap-shared] PASS`.
#
# Default boots ship NO /etc/mmap-shared-test file, so the self-test is a
# no-op skip everywhere else.
#
# Pass marker:  [test_mmap_shared_file] PASS
# Fail marker:  [test_mmap_shared_file] FAIL

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf
BOOT_TIMEOUT="${MMAP_SHARED_BOOT_TIMEOUT:-120}"

echo "[test_mmap_shared_file] (1/3) Build userland (init)"
bash scripts/build_user.sh >/dev/null

echo "[test_mmap_shared_file] (2/3) Build kernel with /etc/mmap-shared-test marker"
INIT_ELF=build/user/init.elf ENABLE_MMAP_SHARED_TEST=1 \
    python3 scripts/build_initramfs.py >/dev/null
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1 || true' EXIT

echo "[test_mmap_shared_file] (3/3) Boot QEMU and run the shared-mmap self-test"
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

echo "[test_mmap_shared_file] --- shared-mmap self-test output ---"
grep -a -E "\[mmap-shared\]|\[boot:37.mms\]" "$LOG" || true
echo "[test_mmap_shared_file] --- end ---"

fail=0

# rc=124 is the expected timeout kill (kernel halts without powering off
# qemu); rc=0 a clean shutdown. Anything else is a real QEMU failure.
if [ "$rc" -ne 0 ] && [ "$rc" -ne 124 ]; then
    echo "[test_mmap_shared_file] FAIL: qemu exited rc=$rc" >&2
    fail=1
fi

# An explicit internal failure is fatal.
if grep -a -qF "[mmap-shared] FAIL" "$LOG"; then
    echo "[test_mmap_shared_file] FAIL: kernel self-test reported an internal failure" >&2
    grep -a -F "[mmap-shared] FAIL" "$LOG" >&2 || true
    fail=1
fi

if ! grep -a -qF "[mmap-shared] PASS" "$LOG"; then
    echo "[test_mmap_shared_file] FAIL: '[mmap-shared] PASS' not found in serial log." >&2
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_mmap_shared_file] FAIL"
    exit 1
fi

echo "[test_mmap_shared_file] PASS — MAP_SHARED writable file mmap writes back to the file"
