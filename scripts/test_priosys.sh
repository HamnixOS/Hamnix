#!/usr/bin/env bash
# scripts/test_priosys.sh — getpriority/setpriority round-trip verification.
#
# Proves the priority syscalls (linux_abi/u_syscalls.ad _u_getpriority /
# _u_setpriority) are backed by the REAL per-task POSIX nice store
# (kernel/sched/core.ad sched_get_nice/sched_set_nice, keyed by task slot)
# instead of returning hardcoded values. The in-kernel
# priority_syscall_selftest() (gated on the cpio marker /etc/priosys-test) SETs
# nice=5 via setpriority, asserts the real store took it, GETs it back via
# getpriority and asserts the biased 20-nice ABI form (== 15), then restores
# the saved nice. The selftest does all the work and needs NO extra QEMU disk.
#
# Boot path: a raw 64-bit Hamnix ELF will NOT boot under `qemu -kernel` on
# this host; the _kernel_iso.sh PATH shim (sourced by _build_lock.sh)
# transparently wraps the ELFCLASS64 kernel in a BIOS GRUB ISO, so the
# `-kernel "$ELF"` invocation below boots through the ISO shim.
#
# Pass marker:  [test_priosys] PASS   (kernel prints [PRIOSYS] PASS)
# Fail marker:  [test_priosys] FAIL

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

export HAMNIX_BUILD_LOCK_TIMEOUT="${HAMNIX_BUILD_LOCK_TIMEOUT:-900}"

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf

LOG=${HAMNIX_PRIOSYS_LOG:-$(mktemp)}
trap 'INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1 || true' EXIT

echo "[test_priosys] (1/3) Build userland + plant /etc/priosys-test + /init"
bash scripts/build_user.sh >/dev/null
INIT_ELF="$HAMSH_ELF" ENABLE_PRIOSYS_TEST=1 \
    python3 scripts/build_initramfs.py >/dev/null

echo "[test_priosys] (2/3) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

echo "[test_priosys] (3/3) Boot QEMU (no extra disk needed)"
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

echo "[test_priosys] --- priosys self-test output ---"
grep -a -E "\[PRIOSYS\]" "$LOG" || true
echo "[test_priosys] --- end ---"

fail=0

if grep -a -F -q "[PRIOSYS] FAIL" "$LOG"; then
    echo "[test_priosys] FAIL: kernel self-test reported an internal failure" >&2
    grep -a -F "[PRIOSYS] FAIL" "$LOG" >&2 || true
    fail=1
fi

if ! grep -a -F -q "[PRIOSYS] PASS" "$LOG"; then
    echo "[test_priosys] MISS: self-test PASS banner (expected '[PRIOSYS] PASS')" >&2
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_priosys] --- full log ---"
    cat "$LOG"
    echo "[test_priosys] FAIL (qemu rc=$rc)"
    exit 1
fi

echo "[test_priosys] PASS — getpriority/setpriority round-trip through the per-task nice store" \
     "(qemu rc=$rc)"
