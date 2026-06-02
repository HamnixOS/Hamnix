#!/usr/bin/env bash
# scripts/test_vmstat.sh — /proc/<pid>/stat vsize/rss + getrusage ru_maxrss
# verification.
#
# Proves the three new memory-stat fields are REAL, all computed on demand
# from the VMA iterator (mm/vma.ad task_vsize_bytes / task_rss_pages):
#   /proc/<pid>/stat field 23 (vsize, bytes) via task_vsize_bytes,
#   /proc/<pid>/stat field 24 (rss, pages)   via task_rss_pages,
#   getrusage(2) ru_maxrss (0x20, KB high-water) in _u_getrusage.
# The in-kernel vmstat_selftest() (gated on the cpio marker /etc/vmstat-test)
# walks the boot task's VMAs, asserts vsize/rss are non-zero, then renders the
# rusage struct and asserts ru_maxrss (0x20) >= current rss in KB. The selftest
# does all the work and needs NO extra QEMU disk.
#
# Boot path: a raw 64-bit Hamnix ELF will NOT boot under `qemu -kernel` on
# this host; the _kernel_iso.sh PATH shim (sourced by _build_lock.sh)
# transparently wraps the ELFCLASS64 kernel in a BIOS GRUB ISO, so the
# `-kernel "$ELF"` invocation below boots through the ISO shim.
#
# Pass marker:  [test_vmstat] PASS   (kernel prints [VMSTAT] PASS)
# Fail marker:  [test_vmstat] FAIL

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

export HAMNIX_BUILD_LOCK_TIMEOUT="${HAMNIX_BUILD_LOCK_TIMEOUT:-900}"

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf

LOG=${HAMNIX_VMSTAT_LOG:-$(mktemp)}
trap 'INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1 || true' EXIT

echo "[test_vmstat] (1/3) Build userland + plant /etc/vmstat-test + /init"
bash scripts/build_user.sh >/dev/null
INIT_ELF="$HAMSH_ELF" ENABLE_VMSTAT_TEST=1 \
    python3 scripts/build_initramfs.py >/dev/null

echo "[test_vmstat] (2/3) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

echo "[test_vmstat] (3/3) Boot QEMU (no extra disk needed)"
set +e
timeout 180s qemu-system-x86_64 \
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

echo "[test_vmstat] --- vmstat self-test output ---"
grep -a -E "\[VMSTAT\]" "$LOG" || true
echo "[test_vmstat] --- end ---"

fail=0

if grep -a -F -q "[VMSTAT] FAIL" "$LOG"; then
    echo "[test_vmstat] FAIL: kernel self-test reported an internal failure" >&2
    grep -a -F "[VMSTAT] FAIL" "$LOG" >&2 || true
    fail=1
fi

if ! grep -a -F -q "[VMSTAT] PASS" "$LOG"; then
    echo "[test_vmstat] MISS: self-test PASS banner (expected '[VMSTAT] PASS')" >&2
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_vmstat] --- full log ---"
    cat "$LOG"
    echo "[test_vmstat] FAIL (qemu rc=$rc)"
    exit 1
fi

echo "[test_vmstat] PASS — /proc stat vsize/rss + getrusage ru_maxrss real" \
     "(qemu rc=$rc)"
