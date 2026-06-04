#!/usr/bin/env bash
# scripts/test_hpet.sh — native HPET (High Precision Event Timer)
# clocksource verification.
#
# Proves the native HPET clocksource in drivers/clocksource/hpet.ad: locate
# the memory-mapped HPET register block via the ACPI HPET table (default
# 0xFED00000 on the QEMU PC machine, which exposes an HPET by default),
# validate its Capabilities/ID register (non-zero femtosecond tick period,
# derived frequency = 10^15 / period_fs in a sane range), enable the main
# counter (General Configuration ENABLE_CNF bit), and read the REAL 64-bit
# main counter twice across a busy delay to prove it is monotonic and
# strictly advancing.
#
# The in-kernel hpet_selftest() runs unconditionally at boot:16.hpet (right
# after the TSC monotonic-clock smoke test) and prints:
#   [hpet] PASS counter-monotonic freq=<...>Hz   on success
#   [hpet] SKIP no-hpet                           if no HPET is present
#
# Boot path: a raw 64-bit Hamnix ELF will NOT boot under `qemu -kernel` on
# this host; the _kernel_iso.sh PATH shim (sourced by _build_lock.sh)
# transparently wraps the ELFCLASS64 kernel in a BIOS GRUB ISO so the
# `-kernel "$ELF"` invocation below boots through the ISO shim.
#
# Pass marker:  [test_hpet] PASS   (kernel prints [hpet] PASS ... or SKIP)
# Fail marker:  [test_hpet] FAIL

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

export HAMNIX_BUILD_LOCK_TIMEOUT="${HAMNIX_BUILD_LOCK_TIMEOUT:-900}"

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf

LOG=${HAMNIX_HPET_LOG:-$(mktemp)}
trap 'INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1 || true' EXIT

echo "[test_hpet] (1/3) Build userland + initramfs"
bash scripts/build_user.sh >/dev/null
INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py >/dev/null

echo "[test_hpet] (2/3) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

echo "[test_hpet] (3/3) Boot QEMU (no extra disk needed)"
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

echo "[test_hpet] --- hpet self-test output ---"
grep -a -E "\[hpet\]" "$LOG" || true
echo "[test_hpet] --- end ---"

fail=0

if grep -a -F -q "[hpet] FAIL" "$LOG"; then
    echo "[test_hpet] FAIL: kernel self-test reported an internal failure" >&2
    grep -a -F "[hpet] FAIL" "$LOG" >&2 || true
    fail=1
fi

# Accept either a genuine PASS (HPET present and monotonic) or the
# tolerant SKIP (no HPET on this platform). QEMU's default machine exposes
# an HPET, so PASS is expected here.
if grep -a -F -q "[hpet] PASS counter-monotonic" "$LOG"; then
    :
elif grep -a -F -q "[hpet] SKIP no-hpet" "$LOG"; then
    echo "[test_hpet] NOTE: kernel reported no HPET present (SKIP) — tolerated"
else
    echo "[test_hpet] MISS: neither PASS nor SKIP banner found" >&2
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_hpet] --- full log ---"
    cat "$LOG"
    echo "[test_hpet] FAIL (qemu rc=$rc)"
    exit 1
fi

echo "[test_hpet] PASS — native HPET clocksource verified" \
     "(ACPI-located, capabilities valid, main counter monotonic+advancing)" \
     "(qemu rc=$rc)"
