#!/usr/bin/env bash
# scripts/test_perf.sh — perf_event_open(2) software-counter verification.
#
# Proves the Linux-ABI perf syscall (linux_abi/u_perf.ad uperf_event_open,
# dispatched from linux_abi/u_syscalls.ad at nr 298, with read/ioctl serviced
# via the FD_PERF_MARK arms in _u_read_body / _u_ioctl) is backed by REAL
# per-task accumulators the kernel ALREADY maintains for /proc/<pid>/stat and
# getrusage(2) — utime/stime ticks, minflt/majflt page faults, nvcsw/nivcsw
# context switches — instead of returning ENOSYS. The in-kernel
# do_perf_selftest() (gated on the cpio marker /etc/perf-test) runs the
# perf-shaped checks:
#   (1) open disabled TASK_CLOCK + CONTEXT_SWITCHES events; both read 0
#   (2) ENABLE both, do measurable work (touch fresh pages + a yield loop),
#       read both and assert CONTEXT_SWITCHES advanced and stays monotonic
#   (3) RESET and assert the next read dropped toward zero
# The selftest does all the work and needs NO extra QEMU disk.
#
# Boot path: a raw 64-bit Hamnix ELF will NOT boot under `qemu -kernel` on this
# host; the _kernel_iso.sh PATH shim (sourced by _build_lock.sh) transparently
# wraps the ELFCLASS64 kernel in a BIOS GRUB ISO, so the `-kernel "$ELF"`
# invocation below boots through the ISO shim.
#
# Pass marker:  [test_perf] PASS   (kernel prints [perf] PASS)
# Fail marker:  [test_perf] FAIL

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

export HAMNIX_BUILD_LOCK_TIMEOUT="${HAMNIX_BUILD_LOCK_TIMEOUT:-900}"

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf

LOG=${HAMNIX_PERF_LOG:-$(mktemp)}
trap 'INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1 || true' EXIT

echo "[test_perf] (1/3) Build userland + plant /etc/perf-test + /init"
bash scripts/build_user.sh >/dev/null
INIT_ELF="$HAMSH_ELF" ENABLE_PERF_TEST=1 \
    python3 scripts/build_initramfs.py >/dev/null

echo "[test_perf] (2/3) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

echo "[test_perf] (3/3) Boot QEMU (no extra disk needed)"
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

echo "[test_perf] --- perf self-test output ---"
grep -a -E "\[PERF\]|\[perf\]" "$LOG" || true
echo "[test_perf] --- end ---"

fail=0

if grep -a -F -q "[perf] FAIL" "$LOG"; then
    echo "[test_perf] FAIL: kernel self-test reported an internal failure" >&2
    grep -a -F "[perf] FAIL" "$LOG" >&2 || true
    fail=1
fi

if ! grep -a -F -q "[perf] PASS" "$LOG"; then
    echo "[test_perf] MISS: self-test PASS banner (expected '[perf] PASS')" >&2
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_perf] --- full log ---"
    cat "$LOG"
    echo "[test_perf] FAIL (qemu rc=$rc)"
    exit 1
fi

echo "[test_perf] PASS — perf_event_open software counters over the real" \
     "per-task accumulators (qemu rc=$rc)"
