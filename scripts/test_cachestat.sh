#!/usr/bin/env bash
# scripts/test_cachestat.sh — cachestat(2) (nr 451) round-trip verification.
#
# Proves the Linux-ABI cachestat syscall (linux_abi/u_cachestat.ad
# cachestat_handler, dispatched from linux_abi/u_syscalls.ad at nr 451) is a
# REAL query of Hamnix's file page-cache state — NOT an ENOSYS stub and NOT a
# hard-coded answer. The in-kernel cachestat_selftest() (gated on the cpio
# marker /etc/cachestat-test, with the backing file /etc/cachestat-data) runs
# the real checks:
#   (1) file mapped but no page faulted -> nr_cache 0
#   (2) fault 2 pages in via the real populator -> nr_cache 2
#   (3) fault the rest -> nr_cache == page count; writeback/evicted == 0
#   (4) sub-range query [0, 1 page) -> nr_cache 1 (range clamping is real)
#   (5) flags!=0 -> -EINVAL, bad range pointer -> -EFAULT, closed fd -> -EBADF
# The selftest maps the backing file and drives vma_demand_fault directly, so it
# needs NO extra disk.
#
# Boot path: a raw 64-bit Hamnix ELF will NOT boot under `qemu -kernel` on this
# host; the _kernel_iso.sh PATH shim (sourced by _build_lock.sh) transparently
# wraps the ELFCLASS64 kernel in a BIOS GRUB ISO, so the `-kernel "$ELF"`
# invocation below boots through the ISO shim.
#
# Pass marker:  [test_cachestat] PASS   (kernel prints [cachestat] PASS)
# Fail marker:  [test_cachestat] FAIL

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

export HAMNIX_BUILD_LOCK_TIMEOUT="${HAMNIX_BUILD_LOCK_TIMEOUT:-900}"

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf

LOG=${HAMNIX_CACHESTAT_LOG:-$(mktemp)}
trap 'INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1 || true' EXIT

echo "[test_cachestat] (1/3) Build userland + plant /etc/cachestat-test + /init"
bash scripts/build_user.sh >/dev/null
INIT_ELF="$HAMSH_ELF" ENABLE_CACHESTAT_TEST=1 \
    python3 scripts/build_initramfs.py >/dev/null

echo "[test_cachestat] (2/3) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

echo "[test_cachestat] (3/3) Boot QEMU (no extra disk needed)"
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

echo "[test_cachestat] --- cachestat self-test output ---"
grep -a -E "\[cachestat\]" "$LOG" || true
echo "[test_cachestat] --- end ---"

fail=0

if grep -a -F -q "[cachestat] FAIL" "$LOG"; then
    echo "[test_cachestat] FAIL: kernel self-test reported an internal failure" >&2
    grep -a -F "[cachestat] FAIL" "$LOG" >&2 || true
    fail=1
fi

if grep -a -F -q "[cachestat] self-test reported FAIL" "$LOG"; then
    echo "[test_cachestat] FAIL: cachestat_selftest returned failure" >&2
    fail=1
fi

if ! grep -a -F -q "[cachestat] PASS" "$LOG"; then
    echo "[test_cachestat] MISS: self-test PASS banner (expected '[cachestat] PASS')" >&2
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_cachestat] --- full log ---"
    cat "$LOG"
    echo "[test_cachestat] FAIL (qemu rc=$rc)"
    exit 1
fi

echo "[test_cachestat] PASS — cachestat reports real page-cache residency:" \
     "nr_cache tracks demand-faulted pages, sub-range clamped, error paths" \
     "(EINVAL/EFAULT/EBADF) correct (qemu rc=$rc)"
