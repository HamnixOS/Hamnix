#!/usr/bin/env bash
# scripts/test_procctl.sh — Plan 9 /proc/<pid>/ctl write-surface verification.
#
# Proves the NATIVE Plan 9 priority-control interface: writing "pri -5\n" to
# /proc/<pid>/ctl sets the target task's per-task POSIX nice. In Plan 9
# "everything is a file" — process control happens via a write to a ctl file,
# NOT a syscall (the Linux getpriority/setpriority syscalls are a separate
# compat surface). The in-kernel procctl_selftest() (gated on the cpio marker
# /etc/procctl-test) drives the REAL _ctl_parse_pri parser on a "pri -5"
# control message, applies it via sched_set_nice, and asserts
# sched_get_nice(boot_slot)==-5, then restores nice to 0. The selftest does all
# the work and needs NO extra QEMU disk.
#
# Boot path: a raw 64-bit Hamnix ELF will NOT boot under `qemu -kernel` on
# this host; the _kernel_iso.sh PATH shim (sourced by _build_lock.sh)
# transparently wraps the ELFCLASS64 kernel in a BIOS GRUB ISO, so the
# `-kernel "$ELF"` invocation below boots through the ISO shim.
#
# Pass marker:  [test_procctl] PASS   (kernel prints [PROCCTL] PASS)
# Fail marker:  [test_procctl] FAIL

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

export HAMNIX_BUILD_LOCK_TIMEOUT="${HAMNIX_BUILD_LOCK_TIMEOUT:-900}"

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf

LOG=${HAMNIX_PROCCTL_LOG:-$(mktemp)}
trap 'INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1 || true' EXIT

echo "[test_procctl] (1/3) Build userland + plant /etc/procctl-test + /init"
bash scripts/build_user.sh >/dev/null
INIT_ELF="$HAMSH_ELF" ENABLE_PROCCTL_TEST=1 \
    python3 scripts/build_initramfs.py >/dev/null

echo "[test_procctl] (2/3) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

echo "[test_procctl] (3/3) Boot QEMU (no extra disk needed)"
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

echo "[test_procctl] --- procctl self-test output ---"
grep -a -E "\[PROCCTL\]" "$LOG" || true
echo "[test_procctl] --- end ---"

fail=0

if grep -a -F -q "[PROCCTL] FAIL" "$LOG"; then
    echo "[test_procctl] FAIL: kernel self-test reported an internal failure" >&2
    grep -a -F "[PROCCTL] FAIL" "$LOG" >&2 || true
    fail=1
fi

if ! grep -a -F -q "[PROCCTL] PASS" "$LOG"; then
    echo "[test_procctl] MISS: self-test PASS banner (expected '[PROCCTL] PASS')" >&2
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_procctl] --- full log ---"
    cat "$LOG"
    echo "[test_procctl] FAIL (qemu rc=$rc)"
    exit 1
fi

echo "[test_procctl] PASS — Plan 9 /proc/<pid>/ctl 'pri -5' write set the per-task nice" \
     "(qemu rc=$rc)"
