#!/usr/bin/env bash
# scripts/test_mmap_file.sh — §file-mmap: REAL file-backed mmap.
#
# The native SYS_MMAP handler (arch/x86/kernel/syscall.ad) used to reject
# any non-anonymous (fd-backed) mmap with -ENOSYS. This fixture proves
# the new file-backed path: a file's contents are mapped into a user VMA
# and the backing pages are read LAZILY on page fault (demand paging),
# exactly like Linux mmap(fd).
#
# Mechanism (pure boot self-test, no userland interaction):
#   1. scripts/build_initramfs.py honours ENABLE_MMAP_FILE_TEST=1: it
#      plants /etc/mmap-file-test (the gate marker) and a known-content
#      backing file /etc/mmap-file-data whose bytes follow the
#      deterministic formula (i*31 + 7) & 0xFF, length = 2 pages + 100.
#   2. init/main.ad at boot:37.mmf detects the marker and runs
#      mmap_file_selftest(): it snapshots the fd's stable backing
#      identity, CLOSES the fd (POSIX), builds a file-backed demand VMA
#      via vma_alloc_file_demand, faults every page in through the real
#      populator (vma_demand_fault's is_file branch reads file bytes),
#      and asserts:
#        * the mapped bytes equal the content formula over [0, size)
#          (multi-page fault-in from a file),
#        * the sub-page EOF tail (bytes past size in the last page)
#          reads as ZERO,
#        * a SECOND mapping at in-file offset 4096 reads the file
#          content starting at byte 4096 (offset handling).
#   3. We boot the kernel (the _build_lock.sh qemu shim wraps the
#      64-bit ELF in a BIOS GRUB ISO automatically) and grep the serial
#      log for `[mmap-file] PASS`.
#
# Default boots ship NO /etc/mmap-file-* files, so the self-test is a
# no-op skip everywhere else.
#
# Pass marker:  [test_mmap_file] PASS
# Fail marker:  [test_mmap_file] FAIL

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf
BOOT_TIMEOUT="${MMAP_FILE_BOOT_TIMEOUT:-120}"

echo "[test_mmap_file] (1/3) Build userland (init)"
bash scripts/build_user.sh >/dev/null

echo "[test_mmap_file] (2/3) Build kernel with /etc/mmap-file-test marker"
INIT_ELF=build/user/init.elf ENABLE_MMAP_FILE_TEST=1 \
    python3 scripts/build_initramfs.py >/dev/null
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1 || true' EXIT

echo "[test_mmap_file] (3/3) Boot QEMU and run the file-mmap self-test"
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

echo "[test_mmap_file] --- file-mmap self-test output ---"
grep -a -E "\[mmap-file\]|\[boot:37.mmf\]" "$LOG" || true
echo "[test_mmap_file] --- end ---"

fail=0

# rc=124 is the expected timeout kill (kernel halts without powering off
# qemu); rc=0 a clean shutdown. Anything else is a real QEMU failure.
if [ "$rc" -ne 0 ] && [ "$rc" -ne 124 ]; then
    echo "[test_mmap_file] FAIL: qemu exited rc=$rc" >&2
    fail=1
fi

# An explicit internal failure is fatal.
if grep -a -qF "[mmap-file] FAIL" "$LOG"; then
    echo "[test_mmap_file] FAIL: kernel self-test reported an internal failure" >&2
    grep -a -F "[mmap-file] FAIL" "$LOG" >&2 || true
    fail=1
fi

if ! grep -a -qF "[mmap-file] PASS" "$LOG"; then
    echo "[test_mmap_file] FAIL: '[mmap-file] PASS' not found in serial log." >&2
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_mmap_file] FAIL"
    exit 1
fi

echo "[test_mmap_file] PASS — file-backed mmap maps real file bytes lazily on fault"
