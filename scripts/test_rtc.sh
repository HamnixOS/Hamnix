#!/usr/bin/env bash
# scripts/test_rtc.sh — V5.2 RTC regression.
#
# Verifies drivers/rtc/cmos.ad reads the CMOS chip cleanly at boot.
# Closes the clock-rollback gap that V5.1 disclosed: previously
# drivers/net/tls.ad::_tls_now_unix would silently fall back to a
# build-epoch when the RTC was unavailable, so an attacker who
# stalled the chip could present a long-expired cert and still get
# it validated. The fallback now logs a WARNING; this test asserts
# that on a normal QEMU boot the fallback DOES NOT fire — the real
# RTC value flows through.
#
# Pipeline (mirrors test_devsysinfo.sh shape):
#   1. Build userland (hamsh, coreutils).
#   2. Build tests/test_rtc.ad as a userspace ELF (auto-globbed by
#      build_initramfs.py into /bin/test_rtc).
#   3. Plant hamsh as /init.
#   4. Rebuild the kernel image so the cmos.ad rtc_read_unix_time +
#      _tls_now_unix changes are linked in.
#   5. Boot QEMU, drive /bin/test_rtc via hamsh, grep the log.
#
# QEMU's emulated MC146818 returns realistic values by default — the
# host wall clock surfaces as the guest RTC, so the parsed `unix=`
# value will be within a few seconds of `date +%s` on the host.
#
# PASS markers:
#   - "[rtc] start"                   (fixture banner)
#   - "rtc: boot epoch = <epoch>"     (kernel-side rtc_init banner)
#   - "[rtc] PASS unix=<digits>"      (fixture verified epoch in range)
# FAIL markers (any of these aborts):
#   - "[rtc] FAIL: ..."               (per-assertion failure)
#   - "[tls] WARNING: RTC unavailable" appearing during a clean boot
#     would mean the build-epoch fallback fired — also a fail.

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf
TEST_ELF=build/user/test_rtc.elf

echo "[test_rtc] (1/5) Build userland (hamsh + coreutils)"
bash scripts/build_user.sh >/dev/null
bash scripts/build_modules.sh >/dev/null

echo "[test_rtc] (2/5) Build tests/test_rtc.ad -> $TEST_ELF"
python3 -m compiler.adder compile \
    --target=x86_64-adder-user \
    tests/test_rtc.ad \
    -o "$TEST_ELF" >/dev/null

echo "[test_rtc] (3/5) Plant /init = hamsh + /bin/test_rtc in cpio"
INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py >/dev/null

echo "[test_rtc] (4/5) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

echo "[test_rtc] (5/5) Boot QEMU + drive /bin/test_rtc via hamsh"
LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null' EXIT

set +e
(
    sleep 3
    printf '/bin/test_rtc\n'
    sleep 2
    printf 'echo POST_RTC_OK\n'
    sleep 1
    printf 'exit\n'
    sleep 1
) | timeout 15s qemu-system-x86_64 \
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

echo "[test_rtc] --- captured output ---"
cat "$LOG"
echo "[test_rtc] --- end output ---"

fail=0

# Kernel-side banner — proves drivers/rtc/cmos.ad::rtc_init() ran
# and snapshotted the epoch into the boot cache.
if grep -E -q "rtc: boot epoch = [0-9]+" "$LOG"; then
    bk=$(grep -E -o 'rtc: boot epoch = [0-9]+' "$LOG" | head -n1 | awk '{print $5}')
    echo "[test_rtc] OK: kernel rtc_init banner present (epoch=$bk)"
else
    echo "[test_rtc] MISS: kernel rtc_init banner absent"
    fail=1
fi

# Fixture banner — confirms the userspace test actually ran.
if grep -F -q "[rtc] start" "$LOG"; then
    echo "[test_rtc] OK: fixture ran"
else
    echo "[test_rtc] MISS: fixture banner missing"
    fail=1
fi

# Per-assertion FAIL lines should NEVER appear when the chain works.
if grep -F -q "[rtc] FAIL:" "$LOG"; then
    echo "[test_rtc] MISS: per-assertion FAIL line(s) present:"
    grep -F "[rtc] FAIL:" "$LOG" | sed 's/^/  /'
    fail=1
else
    echo "[test_rtc] OK: no per-assertion FAIL lines"
fi

# Final PASS marker — the orchestrator's grep target.
if grep -E -q "\[rtc\] PASS unix=[0-9]+" "$LOG"; then
    epoch=$(grep -E -o '\[rtc\] PASS unix=[0-9]+' "$LOG" | head -n1 | cut -d= -f2)
    echo "[test_rtc] OK: fixture reached PASS, unix=$epoch"
else
    echo "[test_rtc] MISS: [rtc] PASS line absent"
    fail=1
fi

# Sentinel: if the build-epoch fallback fired during a clean QEMU
# boot the security-residual mitigation regressed.
if grep -F -q "[tls] WARNING: RTC unavailable" "$LOG"; then
    echo "[test_rtc] MISS: TLS build-epoch fallback fired on a healthy RTC"
    fail=1
fi

# Hamsh responsiveness sentinel.
if grep -F -q "POST_RTC_OK" "$LOG"; then
    echo "[test_rtc] OK: hamsh remains responsive"
else
    echo "[test_rtc] MISS: hamsh died after /bin/test_rtc"
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_rtc] FAIL (qemu rc=$rc)"
    exit 1
fi

echo "[test_rtc] PASS"
