#!/usr/bin/env bash
# scripts/test_adjtimex.sh — adjtimex(2)/clock_adjtime(2) NTP clock-discipline
# verification.
#
# Proves the Linux-ABI NTP / kernel-clock-discipline syscalls (linux_abi/
# u_adjtimex.ad uadj_adjtimex / uadj_clock_adjtime, dispatched from
# linux_abi/u_syscalls.ad at nr 159/305) are backed by a REAL system-wide
# discipline state (frequency offset in scaled ppm, tick length, single-shot
# offset slew) that is WIRED INTO the CLOCK_REALTIME read path
# (uadj_apply_discipline, called by _u_clock_gettime), instead of returning
# ENOSYS or a store-and-echo stub. The in-kernel adjtimex_selftest() (gated on
# the cpio marker /etc/adjtimex-test) runs:
#   (1) adjtimex(modes=0) -> sane state code + nominal defaults (freq 0,
#       tick 10000) round-trip in the readback
#   (2) out-of-range freq (> MAXFREQ) -> EINVAL; state unchanged
#   (3) unknown modes bit -> EINVAL
#   (4) clock_adjtime on a non-REALTIME clock -> EINVAL
#   (5) ADJ_FREQUENCY +100 ppm: a FIXED raw_ns comes out larger by exactly the
#       +100 ppm fraction through the realtime read hook (realtime speeds up)
#   (6) ADJ_OFFSET +0.5 s single-shot: a CLOCK_REALTIME read moves by at least
#       the applied amount (the slew is observable)
#   (7) ADJ_TICK adjustment stored + bounds-checked
# The selftest does all the work and needs NO extra QEMU disk.
#
# Boot path: a raw 64-bit Hamnix ELF will NOT boot under `qemu -kernel` on this
# host; the _kernel_iso.sh PATH shim (sourced by _build_lock.sh) transparently
# wraps the ELFCLASS64 kernel in a BIOS GRUB ISO, so the `-kernel "$ELF"`
# invocation below boots through the ISO shim.
#
# Pass marker:  [test_adjtimex] PASS   (kernel prints [adjtimex] PASS)
# Fail marker:  [test_adjtimex] FAIL

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

export HAMNIX_BUILD_LOCK_TIMEOUT="${HAMNIX_BUILD_LOCK_TIMEOUT:-900}"

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf

LOG=${HAMNIX_ADJTIMEX_LOG:-$(mktemp)}
trap 'INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1 || true' EXIT

echo "[test_adjtimex] (1/3) Build userland + plant /etc/adjtimex-test + /init"
bash scripts/build_user.sh >/dev/null
INIT_ELF="$HAMSH_ELF" ENABLE_ADJTIMEX_TEST=1 \
    python3 scripts/build_initramfs.py >/dev/null

echo "[test_adjtimex] (2/3) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

echo "[test_adjtimex] (3/3) Boot QEMU (no extra disk needed)"
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

echo "[test_adjtimex] --- adjtimex self-test output ---"
grep -a -E "\[ADJTIMEX\]|\[adjtimex\]" "$LOG" || true
echo "[test_adjtimex] --- end ---"

fail=0

if grep -a -F -q "[ADJTIMEX] FAIL" "$LOG"; then
    echo "[test_adjtimex] FAIL: kernel self-test reported an internal failure" >&2
    grep -a -F "[ADJTIMEX] FAIL" "$LOG" >&2 || true
    fail=1
fi

if ! grep -a -F -q "[adjtimex] PASS" "$LOG"; then
    echo "[test_adjtimex] MISS: self-test PASS banner (expected '[adjtimex] PASS')" >&2
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_adjtimex] --- full log ---"
    cat "$LOG"
    echo "[test_adjtimex] FAIL (qemu rc=$rc)"
    exit 1
fi

echo "[test_adjtimex] PASS — adjtimex/clock_adjtime discipline freq/tick/offset" \
     "is real and observable in the CLOCK_REALTIME read path (qemu rc=$rc)"
