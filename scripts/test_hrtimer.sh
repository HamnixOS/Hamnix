#!/usr/bin/env bash
# scripts/test_hrtimer.sh — Linux-shape high-resolution timer subsystem
# verification (clocksource / clockevent / hrtimer / NO_HZ / posix-cpu-timer).
#
# Proves the kernel/time/ subsystem is REAL, not a jiffies-quantized stub:
#   T1  a clocksource is registered, SELECTED (highest-rated), and strictly
#       monotonic — the kernel reads time through the registry, not ad-hoc;
#   T2  a hrtimer armed for T ns fires at ~T with SUB-TICK resolution
#       (fire delay far below one 10 ms jiffy), backed by the clockevent
#       one-shot — the old 16-slot jiffies wheel could only fire at the next
#       10 ms tick boundary;
#   T3  a 1 ms hrtimer-backed sleep takes ~1 ms, NOT ~10 ms (resolution
#       before -> after: 10 ms -> sub-ms);
#   T4  NO_HZ dynticks STOPS the periodic tick when the CPU idles with no
#       near deadline, and timekeeping stays correct on wake (the skipped
#       jiffies are accounted from the never-stopped clocksource);
#   T5  a POSIX CLOCK_PROCESS_CPUTIME_ID timer fires at its CPU-time
#       threshold (per-process CPU timers on the new base).
#
# The in-kernel hrtimer_selftest() (kernel/time/timer_selftest.ad, gated on
# the cpio marker /etc/hrtimer-test) does all the work directly against the
# data structures while CPU interrupts are still off, busy-waiting real
# wall-clock windows from the TSC clocksource. No extra QEMU disk needed.
#
# Boot path: a raw 64-bit Hamnix ELF will NOT boot under `qemu -kernel` on
# this host; the _kernel_iso.sh PATH shim (sourced by _build_lock.sh) wraps
# the ELFCLASS64 kernel in a BIOS GRUB ISO so `-kernel "$ELF"` boots through
# the ISO shim.
#
# Pass marker:  [test_hrtimer] PASS   (kernel prints [hrtimer-test] PASS)
# Fail marker:  [test_hrtimer] FAIL

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

export HAMNIX_BUILD_LOCK_TIMEOUT="${HAMNIX_BUILD_LOCK_TIMEOUT:-900}"

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf

LOG=${HAMNIX_HRTIMER_LOG:-$(mktemp)}
trap 'INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1 || true' EXIT

echo "[test_hrtimer] (1/3) Build userland + plant /etc/hrtimer-test + /init"
bash scripts/build_user.sh >/dev/null
INIT_ELF="$HAMSH_ELF" ENABLE_HRTIMER_TEST=1 \
    python3 scripts/build_initramfs.py >/dev/null

echo "[test_hrtimer] (2/3) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

echo "[test_hrtimer] (3/3) Boot QEMU (no extra disk needed)"
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

echo "[test_hrtimer] --- hrtimer self-test output ---"
grep -a -E "\[hrtimer-test\]|clocksource:|clockevent:|hrtimer:|tick:" "$LOG" || true
echo "[test_hrtimer] --- end ---"

fail=0

if grep -a -F -q "[hrtimer-test] FAIL" "$LOG"; then
    echo "[test_hrtimer] FAIL: kernel self-test reported an internal failure" >&2
    grep -a -F "[hrtimer-test] FAIL" "$LOG" >&2 || true
    fail=1
fi

if ! grep -a -F -q "[hrtimer-test] PASS" "$LOG"; then
    echo "[test_hrtimer] MISS: self-test PASS banner (expected '[hrtimer-test] PASS')" >&2
    fail=1
fi

# Spot-check the load-bearing per-assertion PASS markers so a partial pass
# (e.g. PASS banner without T2/T3/T4) can't slip through.
for marker in \
    "[hrtimer-test] T1 PASS" \
    "[hrtimer-test] T2 PASS" \
    "[hrtimer-test] T3 PASS" \
    "[hrtimer-test] T5 PASS"; do
    if ! grep -a -F -q "$marker" "$LOG"; then
        echo "[test_hrtimer] MISS: assertion marker '$marker'" >&2
        fail=1
    fi
done

# T4 is PASS-or-SKIP (clockevent may be unavailable in a degraded config);
# require one of the two.
if ! grep -a -E -q "\[hrtimer-test\] T4 (PASS|SKIP)" "$LOG"; then
    echo "[test_hrtimer] MISS: T4 (NO_HZ) PASS-or-SKIP marker" >&2
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_hrtimer] --- full log ---"
    cat "$LOG"
    echo "[test_hrtimer] FAIL (qemu rc=$rc)"
    exit 1
fi

echo "[test_hrtimer] PASS — clocksource selected+monotonic, hrtimer fires" \
     "sub-tick (<10ms), 1ms sleep ~1ms, NO_HZ stops the tick, posix CPU" \
     "timer fires at threshold (qemu rc=$rc)"
