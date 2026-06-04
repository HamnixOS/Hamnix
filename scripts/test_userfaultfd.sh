#!/usr/bin/env bash
# scripts/test_userfaultfd.sh — userfaultfd(2) demand-paging-in-userspace
# round-trip verification.
#
# Proves the Linux-ABI userfaultfd(2) syscall (linux_abi/u_userfaultfd.ad
# uffd_create / uffd_ioctl / uffd_read, dispatched from linux_abi/u_syscalls.ad
# at nr 323, with the REAL #PF hook uffd_pagefault_hook wired into
# arch/x86/kernel/trap_diag.ad do_page_fault) is a REAL, ENFORCING demand-paging
# primitive instead of a stub. The in-kernel userfaultfd_selftest() (gated on the
# cpio marker /etc/userfaultfd-test) runs the full round-trip:
#   (1) userfaultfd() -> a uffd fd (FD_UFFD_MARK)
#   (2) UFFDIO_API handshake (a wrong magic -> EINVAL)
#   (3) mmap an anonymous demand region (vma_alloc_demand)
#   (4) UFFDIO_REGISTER it for MISSING faults (bad mode/align -> EINVAL)
#   (5) simulate a fault: the #PF hook claims it + enqueues a uffd_msg
#       (demand-zero SUPPRESSED), ignores an out-of-range fault
#   (6) read the uffd_msg and assert event/address are exact
#   (7) UFFDIO_COPY known bytes into the faulted page (real mm mapping path)
#   (8) read the page back at its user vaddr — bytes round-trip BYTE-EXACT
#   (9) UFFDIO_ZEROPAGE a second page -> reads back all-zero
# The selftest does all the work and needs NO extra QEMU disk.
#
# Boot path: a raw 64-bit Hamnix ELF will NOT boot under `qemu -kernel` on this
# host; the _kernel_iso.sh PATH shim (sourced by _build_lock.sh) transparently
# wraps the ELFCLASS64 kernel in a BIOS GRUB ISO, so the `-kernel "$ELF"`
# invocation below boots through the ISO shim.
#
# Pass marker:  [test_userfaultfd] PASS   (kernel prints [userfaultfd] PASS)
# Fail marker:  [test_userfaultfd] FAIL

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

export HAMNIX_BUILD_LOCK_TIMEOUT="${HAMNIX_BUILD_LOCK_TIMEOUT:-900}"

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf

LOG=${HAMNIX_USERFAULTFD_LOG:-$(mktemp)}
trap 'INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1 || true' EXIT

echo "[test_userfaultfd] (1/3) Build userland + plant /etc/userfaultfd-test + /init"
bash scripts/build_user.sh >/dev/null
INIT_ELF="$HAMSH_ELF" ENABLE_USERFAULTFD_TEST=1 \
    python3 scripts/build_initramfs.py >/dev/null

echo "[test_userfaultfd] (2/3) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

echo "[test_userfaultfd] (3/3) Boot QEMU (no extra disk needed)"
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

echo "[test_userfaultfd] --- userfaultfd self-test output ---"
grep -a -E "\[USERFAULTFD\]|\[userfaultfd\]" "$LOG" || true
echo "[test_userfaultfd] --- end ---"

fail=0

if grep -a -F -q "[USERFAULTFD] FAIL" "$LOG"; then
    echo "[test_userfaultfd] FAIL: kernel self-test reported an internal failure" >&2
    grep -a -F "[USERFAULTFD] FAIL" "$LOG" >&2 || true
    fail=1
fi

if ! grep -a -F -q "[userfaultfd] PASS" "$LOG"; then
    echo "[test_userfaultfd] MISS: self-test PASS banner (expected '[userfaultfd] PASS')" >&2
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_userfaultfd] --- full log ---"
    cat "$LOG"
    echo "[test_userfaultfd] FAIL (qemu rc=$rc)"
    exit 1
fi

echo "[test_userfaultfd] PASS — userfaultfd register/fault/COPY round-trip through" \
     "the real mm mapping path (qemu rc=$rc)"
