#!/usr/bin/env bash
# scripts/test_futexv.sh — futex_waitv(2) (nr 449) wait-on-vector verification.
#
# Proves the Linux-ABI futex_waitv syscall (linux_abi/u_futexv.ad futexv_waitv,
# dispatched from linux_abi/u_syscalls.ad at nr 449) is a REAL vector wait —
# parking the caller against EVERY uaddr in the waiters array via the existing
# futex wait table and returning the woken element's index — instead of
# returning ENOSYS. The in-kernel futexv_selftest() (gated on the cpio marker
# /etc/futexv-test) runs the man-page-shaped checks:
#   (1) a 2-element waiters array whose second word already mismatches its
#       expected value -> the enqueue fast path returns -EAGAIN
#   (2) both words match, no other live peer -> the multi-uaddr park registers
#       and unwinds, returning the budgeted -EAGAIN
#   (3) bad syscall flags / nr_futexes==0 / nr>128 / bad FUTEX2 size selector /
#       __reserved!=0 / NULL waiters are each rejected with -EINVAL
# The selftest does all the work and needs NO extra QEMU disk.
#
# Boot path: a raw 64-bit Hamnix ELF will NOT boot under `qemu -kernel` on this
# host; the _kernel_iso.sh PATH shim (sourced by _build_lock.sh) transparently
# wraps the ELFCLASS64 kernel in a BIOS GRUB ISO, so the `-kernel "$ELF"`
# invocation below boots through the ISO shim.
#
# Pass marker:  [test_futexv] PASS   (kernel prints [futexv] PASS)
# Fail marker:  [test_futexv] FAIL

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

export HAMNIX_BUILD_LOCK_TIMEOUT="${HAMNIX_BUILD_LOCK_TIMEOUT:-900}"

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf

LOG=${HAMNIX_FUTEXV_LOG:-$(mktemp)}
trap 'INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1 || true' EXIT

echo "[test_futexv] (1/3) Build userland + plant /etc/futexv-test + /init"
bash scripts/build_user.sh >/dev/null
INIT_ELF="$HAMSH_ELF" ENABLE_FUTEXV_TEST=1 \
    python3 scripts/build_initramfs.py >/dev/null

echo "[test_futexv] (2/3) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

echo "[test_futexv] (3/3) Boot QEMU (no extra disk needed)"
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

echo "[test_futexv] --- futexv self-test output ---"
grep -a -E "\[FUTEXV\]|\[futexv\]" "$LOG" || true
echo "[test_futexv] --- end ---"

fail=0

if grep -a -F -q "[FUTEXV] FAIL" "$LOG"; then
    echo "[test_futexv] FAIL: kernel self-test reported an internal failure" >&2
    grep -a -F "[FUTEXV] FAIL" "$LOG" >&2 || true
    fail=1
fi

if ! grep -a -F -q "[futexv] PASS" "$LOG"; then
    echo "[test_futexv] MISS: self-test PASS banner (expected '[futexv] PASS')" >&2
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_futexv] --- full log ---"
    cat "$LOG"
    echo "[test_futexv] FAIL (qemu rc=$rc)"
    exit 1
fi

echo "[test_futexv] PASS — futex_waitv parks the caller on a vector of futexes" \
     "through the real futex wait table (qemu rc=$rc)"
