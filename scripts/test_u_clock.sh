#!/usr/bin/env bash
# scripts/test_u_clock.sh — clock_gettime(2) high-resolution clock test.
#
# Drives tests/u-binary/u_musl_clock — a musl static-PIE binary that
# fires raw clock_gettime(2) syscalls (Linux x86_64 nr 228) — and
# asserts the Hamnix kernel's TSC-backed monotonic clock and
# RTC-anchored realtime clock both behave.
#
# The fixture reads CLOCK_MONOTONIC twice around a bounded busy spin
# and checks that the second read is strictly greater (monotonic +
# advancing), that the elapsed delta is NOT a whole multiple of 10 ms
# (proving sub-jiffy TSC resolution — the old jiffies handler could
# only ever return 10 ms multiples), and that CLOCK_REALTIME yields a
# plausible post-2020 Unix epoch.
#
# PASS = all four "U-clock:" marker lines present in the transcript:
#   U-clock: monotonic t0 ok
#   U-clock: monotonic advanced
#   U-clock: hires ok
#   U-clock: realtime ok
#
# Pass marker: [test_u_clock] PASS
# Fail marker: [test_u_clock] FAIL

. "$(dirname "$0")/_build_lock.sh"
. "$(dirname "$0")/_ensure_ubin.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

# Build-on-missing: the fixture is gitignored (host-built). If absent,
# build it from tests/u-binary/src/musl_clock; SKIP only on a genuine
# toolchain failure.
ensure_ubin_or_skip test_u_clock u_musl_clock musl_clock

ELF=build/hamnix-vmlinux.elf
HAMSH_ELF=build/user/hamsh.elf

echo "[test_u_clock] (1/4) Build userland"
bash scripts/build_user.sh

echo "[test_u_clock] (2/4) Swap /init = hamsh + embed u_musl_clock"
HAMNIX_EMBED_UBIN=1 INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py

echo "[test_u_clock] (3/4) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF"

echo "[test_u_clock] (4/4) Boot QEMU + run u_musl_clock"
LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null' EXIT

set +e
(
    sleep 4
    printf 'u_musl_clock\n'
    sleep 8
    printf 'exit\n'
    sleep 1
) | timeout 50s qemu-system-x86_64 \
    -kernel "$ELF" \
    -smp 2 \
    -nographic \
    -no-reboot \
    -m 256M \
    -monitor none \
    -serial stdio \
    > "$LOG" 2>&1
rc=$?
set -e

echo "[test_u_clock] --- captured output ---"
cat "$LOG"
echo "[test_u_clock] --- end output ---"

fail=0

check_marker() {
    local label="$1"
    local needle="$2"
    if grep -F -q "$needle" "$LOG"; then
        echo "[test_u_clock] OK: $label"
    else
        echo "[test_u_clock] MISS: $label  ('$needle')"
        fail=1
    fi
}

check_marker "CLOCK_MONOTONIC read"        "U-clock: monotonic t0 ok"
check_marker "monotonic strictly advanced" "U-clock: monotonic advanced"
check_marker "sub-jiffy TSC resolution"    "U-clock: hires ok"
check_marker "CLOCK_REALTIME epoch sane"   "U-clock: realtime ok"

if grep -F -q "U-clock: " "$LOG" && grep -F -q "FAIL" "$LOG"; then
    if grep -E -q "U-clock: .* FAIL" "$LOG"; then
        echo "[test_u_clock] DIAG: fixture reported an internal failure"
        grep -E "U-clock: .* FAIL" "$LOG" | head -5 || true
        fail=1
    fi
fi
if grep -F -q "unknown syscall" "$LOG"; then
    echo "[test_u_clock] DIAG: unknown syscall(s) logged"
    grep -F "unknown syscall" "$LOG" | sort -u | head -10 || true
    fail=1
fi
if grep -F -q "TRAP: vector" "$LOG"; then
    echo "[test_u_clock] DIAG: kernel reported a CPU exception"
    grep -F "TRAP: vector" "$LOG" | head -5 || true
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_u_clock] FAIL (qemu rc=$rc)"
    exit 1
fi

echo "[test_u_clock] PASS — clock_gettime TSC monotonic + RTC realtime verified"
