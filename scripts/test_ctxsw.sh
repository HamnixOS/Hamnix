#!/usr/bin/env bash
# scripts/test_ctxsw.sh — per-task context-switch accounting verification.
#
# Proves the new per-task context-switch counters (kernel/sched/core.ad nvcsw /
# nivcsw, charged from schedule() at the real prev != next switch site via the
# slot-indexed helpers) flow through _u_getrusage (linux_abi/u_syscalls.ad
# ru_nvcsw 0x80 / ru_nivcsw 0x88) and the read accessors. The in-kernel
# ctxsw_selftest() (gated on the cpio marker /etc/ctxsw-test) charges 2
# voluntary + 3 involuntary switches via the same helpers schedule() drives,
# asserts the read accessors rose by exactly 2 / 3, then renders the rusage
# struct and asserts 0x80 / 0x88 match. The selftest does all the work and
# needs NO extra QEMU disk.
#
# Boot path: a raw 64-bit Hamnix ELF will NOT boot under `qemu -kernel` on
# this host; the _kernel_iso.sh PATH shim (sourced by _build_lock.sh)
# transparently wraps the ELFCLASS64 kernel in a BIOS GRUB ISO, so the
# `-kernel "$ELF"` invocation below boots through the ISO shim.
#
# Pass marker:  [test_ctxsw] PASS   (kernel prints [CTXSW] PASS)
# Fail marker:  [test_ctxsw] FAIL

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

export HAMNIX_BUILD_LOCK_TIMEOUT="${HAMNIX_BUILD_LOCK_TIMEOUT:-900}"

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf

LOG=${HAMNIX_CTXSW_LOG:-$(mktemp)}
trap 'INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1 || true' EXIT

echo "[test_ctxsw] (1/3) Build userland + plant /etc/ctxsw-test + /init"
bash scripts/build_user.sh >/dev/null
INIT_ELF="$HAMSH_ELF" ENABLE_CTXSW_TEST=1 \
    python3 scripts/build_initramfs.py >/dev/null

echo "[test_ctxsw] (2/3) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

echo "[test_ctxsw] (3/3) Boot QEMU (no extra disk needed)"
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

echo "[test_ctxsw] --- ctxsw self-test output ---"
grep -a -E "\[CTXSW\]" "$LOG" || true
echo "[test_ctxsw] --- end ---"

fail=0

if grep -a -F -q "[CTXSW] FAIL" "$LOG"; then
    echo "[test_ctxsw] FAIL: kernel self-test reported an internal failure" >&2
    grep -a -F "[CTXSW] FAIL" "$LOG" >&2 || true
    fail=1
fi

if ! grep -a -F -q "[CTXSW] PASS" "$LOG"; then
    echo "[test_ctxsw] MISS: self-test PASS banner (expected '[CTXSW] PASS')" >&2
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_ctxsw] --- full log ---"
    cat "$LOG"
    echo "[test_ctxsw] FAIL (qemu rc=$rc)"
    exit 1
fi

echo "[test_ctxsw] PASS — getrusage reports real per-task context switches" \
     "(qemu rc=$rc)"
