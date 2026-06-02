#!/usr/bin/env bash
# scripts/test_rlimit.sh — getrlimit/setrlimit/prlimit64 round-trip verification.
#
# Proves the rlimit syscalls (linux_abi/u_syscalls.ad _u_prlimit64 /
# _u_getrlimit / _u_setrlimit) are backed by a REAL per-task resource-limit
# store (kernel/sched/core.ad g_rlim_cur/g_rlim_max, keyed by task slot, seeded
# to Linux defaults by rlimit_init_task) instead of returning hardcoded
# defaults. The in-kernel rlimit_selftest() (gated on the cpio marker
# /etc/rlimit-test) SETs RLIMIT_NOFILE to {512,4096} via prlimit64, GETs it
# back and asserts the store persisted, then verifies the seeded 8 MiB
# RLIMIT_STACK default. The selftest does all the work and needs NO extra QEMU
# disk.
#
# Boot path: a raw 64-bit Hamnix ELF will NOT boot under `qemu -kernel` on
# this host; the _kernel_iso.sh PATH shim (sourced by _build_lock.sh)
# transparently wraps the ELFCLASS64 kernel in a BIOS GRUB ISO, so the
# `-kernel "$ELF"` invocation below boots through the ISO shim.
#
# Pass marker:  [test_rlimit] PASS   (kernel prints [RLIMIT] PASS)
# Fail marker:  [test_rlimit] FAIL

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

export HAMNIX_BUILD_LOCK_TIMEOUT="${HAMNIX_BUILD_LOCK_TIMEOUT:-900}"

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf

LOG=${HAMNIX_RLIMIT_LOG:-$(mktemp)}
trap 'INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1 || true' EXIT

echo "[test_rlimit] (1/3) Build userland + plant /etc/rlimit-test + /init"
bash scripts/build_user.sh >/dev/null
INIT_ELF="$HAMSH_ELF" ENABLE_RLIMIT_TEST=1 \
    python3 scripts/build_initramfs.py >/dev/null

echo "[test_rlimit] (2/3) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

echo "[test_rlimit] (3/3) Boot QEMU (no extra disk needed)"
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

echo "[test_rlimit] --- rlimit self-test output ---"
grep -a -E "\[RLIMIT\]" "$LOG" || true
echo "[test_rlimit] --- end ---"

fail=0

if grep -a -F -q "[RLIMIT] FAIL" "$LOG"; then
    echo "[test_rlimit] FAIL: kernel self-test reported an internal failure" >&2
    grep -a -F "[RLIMIT] FAIL" "$LOG" >&2 || true
    fail=1
fi

if ! grep -a -F -q "[RLIMIT] PASS" "$LOG"; then
    echo "[test_rlimit] MISS: self-test PASS banner (expected '[RLIMIT] PASS')" >&2
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_rlimit] --- full log ---"
    cat "$LOG"
    echo "[test_rlimit] FAIL (qemu rc=$rc)"
    exit 1
fi

echo "[test_rlimit] PASS — getrlimit/setrlimit/prlimit64 round-trip through the per-task store" \
     "(qemu rc=$rc)"
