#!/usr/bin/env bash
# scripts/test_procstat_intr.sh — /proc/stat per-IRQ-column verification.
#
# Proves the /proc/stat "intr" line's 16 per-IRQ columns are now REAL
# per-vector interrupt counts (arch/x86/kernel/irq.ad irq_per_vector_count,
# bumped in do_irq for every vector including the timer) rather than the
# old 16 hardcoded zeros, rendered by _build_stat (sys/src/9/port/devstat.ad
# via irq_vector_count, vectors 32..47 = ISA IRQ 0..15).
# The in-kernel procstat_intr_selftest() (gated on the cpio marker
# /etc/procstat-intr-test) lets the timer ISR bump the IRQ0 (vector 32)
# per-vector count, renders /proc/stat into a local buffer, and asserts the
# first per-IRQ column (right after the total) is the real non-zero timer
# count, not the literal 0. The selftest does all the work and needs NO
# extra QEMU disk.
#
# Boot path: a raw 64-bit Hamnix ELF will NOT boot under `qemu -kernel` on
# this host; the _kernel_iso.sh PATH shim (sourced by _build_lock.sh)
# transparently wraps the ELFCLASS64 kernel in a BIOS GRUB ISO, so the
# `-kernel "$ELF"` invocation below boots through the ISO shim.
#
# Pass marker:  [test_procstat_intr] PASS  (kernel prints [PROCSTAT_INTR] PASS)
# Fail marker:  [test_procstat_intr] FAIL

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

export HAMNIX_BUILD_LOCK_TIMEOUT="${HAMNIX_BUILD_LOCK_TIMEOUT:-900}"

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf

LOG=${HAMNIX_PROCSTAT_INTR_LOG:-$(mktemp)}
trap 'INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1 || true' EXIT

echo "[test_procstat_intr] (1/3) Build userland + plant /etc/procstat-intr-test + /init"
bash scripts/build_user.sh >/dev/null
INIT_ELF="$HAMSH_ELF" ENABLE_PROCSTAT_INTR_TEST=1 \
    python3 scripts/build_initramfs.py >/dev/null

echo "[test_procstat_intr] (2/3) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

echo "[test_procstat_intr] (3/3) Boot QEMU (no extra disk needed)"
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

echo "[test_procstat_intr] --- procstat_intr self-test output ---"
grep -a -E "\[PROCSTAT_INTR\]" "$LOG" || true
echo "[test_procstat_intr] --- end ---"

fail=0

if grep -a -F -q "[PROCSTAT_INTR] FAIL" "$LOG"; then
    echo "[test_procstat_intr] FAIL: kernel self-test reported an internal failure" >&2
    grep -a -F "[PROCSTAT_INTR] FAIL" "$LOG" >&2 || true
    fail=1
fi

if ! grep -a -F -q "[PROCSTAT_INTR] PASS" "$LOG"; then
    echo "[test_procstat_intr] MISS: self-test PASS banner (expected '[PROCSTAT_INTR] PASS')" >&2
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_procstat_intr] --- full log ---"
    cat "$LOG"
    echo "[test_procstat_intr] FAIL (qemu rc=$rc)"
    exit 1
fi

echo "[test_procstat_intr] PASS — /proc/stat reports real per-IRQ interrupt counts" \
     "(qemu rc=$rc)"
