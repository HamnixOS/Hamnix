#!/usr/bin/env bash
# scripts/test_process_madvise.sh — process_madvise(2) (nr 440) cross-process
# advice verification.
#
# Proves the Linux-ABI process_madvise syscall (linux_abi/u_process_madvise.ad
# process_madvise_handler, dispatched from linux_abi/u_syscalls.ad at nr 440) is
# backed by a REAL cross-process operation instead of returning ENOSYS or a
# no-op. process_madvise applies an madvise advice to ranges in ANOTHER process
# identified by a pidfd; for MADV_DONTNEED the target's page frames are resolved
# by walking the TARGET task's OWN page table (task_pml4 + uaccess_resolve) and
# zeroed in place, so the target genuinely reads back zero. The in-kernel
# process_madvise_selftest() (gated on the cpio marker /etc/process-madvise-test)
# runs the checks:
#   (1) build a real SECOND task (distinct PML4), map a known page at a
#       non-identity remote vaddr, register a writable VMA over it
#   (2) stamp a non-zero pattern into the remote frame
#   (3) process_madvise(MADV_DONTNEED) the remote range via a pidfd to the target
#   (4) the remote PHYSICAL frame must read back ALL ZERO (observable effect)
#   (5) flags!=0 -> EINVAL; bad advice -> EINVAL; non-pidfd -> EBADF; exited
#       target -> ESRCH
# The selftest does all the work and needs NO extra QEMU disk.
#
# Boot path: a raw 64-bit Hamnix ELF will NOT boot under `qemu -kernel` on this
# host; the _kernel_iso.sh PATH shim (sourced by _build_lock.sh) transparently
# wraps the ELFCLASS64 kernel in a BIOS GRUB ISO, so the `-kernel "$ELF"`
# invocation below boots through the ISO shim.
#
# Pass marker:  [test_process_madvise] PASS   (kernel prints [process_madvise] PASS)
# Fail marker:  [test_process_madvise] FAIL

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

export HAMNIX_BUILD_LOCK_TIMEOUT="${HAMNIX_BUILD_LOCK_TIMEOUT:-900}"

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf

LOG=${HAMNIX_PROCESS_MADVISE_LOG:-$(mktemp)}
trap 'INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1 || true' EXIT

echo "[test_process_madvise] (1/3) Build userland + plant /etc/process-madvise-test + /init"
bash scripts/build_user.sh >/dev/null
INIT_ELF="$HAMSH_ELF" ENABLE_PROCESS_MADVISE_TEST=1 \
    python3 scripts/build_initramfs.py >/dev/null

echo "[test_process_madvise] (2/3) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

echo "[test_process_madvise] (3/3) Boot QEMU (no extra disk needed)"
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

echo "[test_process_madvise] --- process_madvise self-test output ---"
grep -a -E "\[process-madvise\]|\[process_madvise\]" "$LOG" || true
echo "[test_process_madvise] --- end ---"

fail=0

if grep -a -F -q "[process-madvise] FAIL" "$LOG"; then
    echo "[test_process_madvise] FAIL: kernel self-test reported an internal failure" >&2
    grep -a -F "[process-madvise] FAIL" "$LOG" >&2 || true
    fail=1
fi

if ! grep -a -F -q "[process_madvise] PASS" "$LOG"; then
    echo "[test_process_madvise] MISS: self-test PASS banner (expected '[process_madvise] PASS')" >&2
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_process_madvise] --- full log ---"
    cat "$LOG"
    echo "[test_process_madvise] FAIL (qemu rc=$rc)"
    exit 1
fi

echo "[test_process_madvise] PASS — process_madvise applies cross-process advice" \
     "(MADV_DONTNEED observably zeroes the target's page) via the pidfd ->" \
     "target page-walk (qemu rc=$rc)"
