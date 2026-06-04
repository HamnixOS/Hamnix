#!/usr/bin/env bash
# scripts/test_mseal.sh — mseal(2) (x86_64 nr 462) memory-seal verification.
#
# Proves the Linux-ABI mseal syscall (linux_abi/u_mseal.ad umseal_mseal,
# dispatched from linux_abi/u_syscalls.ad at nr 462) really FREEZES a VMA
# address range: a sealed range's mprotect/munmap/mremap/madvise(DONTNEED)
# are rejected -EPERM by the EXISTING mm syscalls (mm/vma.ad vma_protect /
# vma_unmap / vma_mremap / vma_madvise, which consult the per-VMA sealed
# flag) instead of mutating it. The in-kernel umseal_selftest() (gated on
# the cpio marker /etc/mseal-test) runs the checks:
#   (1) mmap a SEALED-to-be region + an UNSEALED control region
#   (2) mseal() the first; assert only it reports sealed
#   (3) mprotect/munmap/mremap/madvise(DONTNEED) on the sealed region all
#       -> EPERM, and the region survives intact
#   (4) the SAME four ops on the UNSEALED region all succeed
#   (5) bad flags -> EINVAL; an unmapped hole -> ENOMEM
# The selftest does all the work and needs NO extra QEMU disk.
#
# Boot path: a raw 64-bit Hamnix ELF will NOT boot under `qemu -kernel` on
# this host; the _kernel_iso.sh PATH shim (sourced by _build_lock.sh) wraps
# the ELFCLASS64 kernel in a BIOS GRUB ISO, so `-kernel "$ELF"` boots via it.
#
# Pass marker:  [test_mseal] PASS   (kernel prints [mseal] PASS)
# Fail marker:  [test_mseal] FAIL

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

export HAMNIX_BUILD_LOCK_TIMEOUT="${HAMNIX_BUILD_LOCK_TIMEOUT:-900}"

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf

LOG=${HAMNIX_MSEAL_LOG:-$(mktemp)}
trap 'INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1 || true' EXIT

echo "[test_mseal] (1/3) Build userland + plant /etc/mseal-test + /init"
bash scripts/build_user.sh >/dev/null
INIT_ELF="$HAMSH_ELF" ENABLE_MSEAL_TEST=1 \
    python3 scripts/build_initramfs.py >/dev/null

echo "[test_mseal] (2/3) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

echo "[test_mseal] (3/3) Boot QEMU (no extra disk needed)"
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

echo "[test_mseal] --- mseal self-test output ---"
grep -a -E "\[MSEAL\]|\[mseal\]" "$LOG" || true
echo "[test_mseal] --- end ---"

fail=0

if grep -a -F -q "[MSEAL] FAIL" "$LOG"; then
    echo "[test_mseal] FAIL: kernel self-test reported an internal failure" >&2
    grep -a -F "[MSEAL] FAIL" "$LOG" >&2 || true
    fail=1
fi

if ! grep -a -F -q "[mseal] PASS" "$LOG"; then
    echo "[test_mseal] MISS: self-test PASS banner (expected '[mseal] PASS')" >&2
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_mseal] --- full log ---"
    cat "$LOG"
    echo "[test_mseal] FAIL (qemu rc=$rc)"
    exit 1
fi

echo "[test_mseal] PASS — a sealed VMA rejects mprotect/munmap/mremap/madvise" \
     "-EPERM while an unsealed region still allows them (qemu rc=$rc)"
