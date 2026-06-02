#!/usr/bin/env bash
# scripts/test_starttime.sh — /proc/<pid>/stat starttime (field 22) check.
#
# Proves the Linux-ABI /proc/<pid>/stat field 22 (starttime) is REAL: the
# jiffy count at task creation, captured write-once in
# sched_init_task_weight (kernel/sched/core.ad start_jiffies, HZ=100, ticks
# since boot) and emitted by _emit_linux_stat. It used to render the literal
# 0. The in-kernel starttime_selftest() (gated on the cpio marker
# /etc/starttime-test) stamps the boot slot's start_jiffies to a known
# sentinel, asserts the accessor reads it back, renders _emit_linux_stat for
# the boot slot, parses field 22, and asserts it equals the sentinel. The
# selftest does all the work and needs NO extra QEMU disk.
#
# Boot path: a raw 64-bit Hamnix ELF will NOT boot under `qemu -kernel` on
# this host; the _kernel_iso.sh PATH shim (sourced by _build_lock.sh)
# transparently wraps the ELFCLASS64 kernel in a BIOS GRUB ISO, so the
# `-kernel "$ELF"` invocation below boots through the ISO shim.
#
# Pass marker:  [test_starttime] PASS   (kernel prints [STARTTIME] PASS)
# Fail marker:  [test_starttime] FAIL

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

export HAMNIX_BUILD_LOCK_TIMEOUT="${HAMNIX_BUILD_LOCK_TIMEOUT:-900}"

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf

LOG=${HAMNIX_STARTTIME_LOG:-$(mktemp)}
trap 'INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1 || true' EXIT

echo "[test_starttime] (1/3) Build userland + plant /etc/starttime-test + /init"
bash scripts/build_user.sh >/dev/null
INIT_ELF="$HAMSH_ELF" ENABLE_STARTTIME_TEST=1 \
    python3 scripts/build_initramfs.py >/dev/null

echo "[test_starttime] (2/3) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

echo "[test_starttime] (3/3) Boot QEMU (no extra disk needed)"
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

echo "[test_starttime] --- starttime self-test output ---"
grep -a -E "\[STARTTIME\]" "$LOG" || true
echo "[test_starttime] --- end ---"

fail=0

if grep -a -F -q "[STARTTIME] FAIL" "$LOG"; then
    echo "[test_starttime] FAIL: kernel self-test reported an internal failure" >&2
    grep -a -F "[STARTTIME] FAIL" "$LOG" >&2 || true
    fail=1
fi

if ! grep -a -F -q "[STARTTIME] PASS" "$LOG"; then
    echo "[test_starttime] MISS: self-test PASS banner (expected '[STARTTIME] PASS')" >&2
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_starttime] --- full log ---"
    cat "$LOG"
    echo "[test_starttime] FAIL (qemu rc=$rc)"
    exit 1
fi

echo "[test_starttime] PASS — /proc/<pid>/stat starttime (field 22) real" \
     "(qemu rc=$rc)"
