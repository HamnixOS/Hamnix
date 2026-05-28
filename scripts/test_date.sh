#!/usr/bin/env bash
# scripts/test_date.sh — verify user/date.ad prints the real wall clock.
#
# Background: until this lands, user/date.ad was a stand-in that
# printed an uptime-shaped readout because there was no RTC plumbing.
# The brief was outdated — drivers/rtc/cmos.ad already snapshots the
# CMOS chip at boot, _u_clock_gettime already serves CLOCK_REALTIME,
# and tls.ad already uses rtc_read_unix_time for cert validity. What
# was missing: a userland-facing /proc/realtime + a date(1) that
# reads it. That's what this test verifies.
#
# Chain:
#   1. drivers/rtc/cmos.ad::rtc_init() reads CMOS at boot, caches
#      the Unix epoch in rtc_boot_epoch.
#   2. fs/procfs.ad::render_realtime() emits a two-line snapshot:
#        <ISO-8601 UTC> <epoch_seconds>
#        <uptime_seconds>.<cs> <jiffies>
#      The first line's first column is what user/date.ad parses.
#   3. user/date.ad reads /proc/realtime, reshapes the ISO-8601
#      timestamp as "YYYY-MM-DD HH:MM:SS UTC", and writes to stdout.
#
# Assertions (in the QEMU log):
#   - "[hamsh] M16.35 shell ready" appears (boot reaches userland)
#   - `date` output contains a 4-digit year matching today's year
#     (we read the year off `date -u +%Y` on the host; QEMU's RTC
#     defaults to host-clock so this is reliable in CI)
#   - `date` output ends with " UTC" — proves the new formatter ran,
#     not the old "up: N.NN seconds" stand-in
#   - `cat /proc/realtime` produces a line starting with that same
#     year (a stronger end-to-end check that the kernel-side render
#     uses the right epoch, not a fallback)
#   - The 10-digit epoch value embedded in /proc/realtime is within
#     a generous 24-hour window of `date -u +%s` on the host
#     (`abs(guest_epoch - host_epoch) < 86400`) — catches the
#     "kernel rendered a wildly wrong epoch" class of bug while
#     tolerating any host/guest clock drift inside QEMU
#
# DRIVER: uses _qemu_drive.sh so the test waits for hamsh's banner
# before sending keystrokes — same pattern as test_named_stack.sh.
# Fixed-sleep input driving is fragile on slow CI hosts (hamsh's
# stage-08 ed-readline must be live before bytes land).

. "$(dirname "$0")/_build_lock.sh"
. "$(dirname "$0")/_qemu_drive.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf
DATE_ELF=build/user/date.elf

echo "[test_date] (1/4) Build userland (date.elf + hamsh.elf)"
bash scripts/build_user.sh >/dev/null
for elf in "$DATE_ELF" "$HAMSH_ELF"; do
    if [ ! -s "$elf" ]; then
        echo "[test_date] FAIL: $elf missing or empty after build."
        exit 1
    fi
done

echo "[test_date] (2/4) Plant hamsh as /init in initramfs"
INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py >/dev/null

echo "[test_date] (3/4) Rebuild kernel"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

echo "[test_date] (4/4) Boot QEMU + drive date / cat /proc/realtime"
LOG=$(mktemp /tmp/test-date.XXXXXX.log)
# Restore /init = init.elf on the way out so the next test isn't
# surprised by an "init = hamsh" initramfs.
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null' EXIT

# Capture host wall clock NOW so we can range-check the guest's
# rendered epoch later. QEMU's emulated MC146818 tracks the host
# RTC by default (and the host_rtc=utc shim in scripts/_kernel_iso.sh
# preserves UTC semantics).
HOST_EPOCH_BEFORE=$(date -u +%s)
HOST_YEAR=$(date -u +%Y)

set +e
# Sentinel echoes wrap each command so we can extract its output
# unambiguously even if hamsh's readline emits per-char redraw noise
# (the [K[NC sequences) — sed between BEGIN/END markers gives us the
# raw stdout lines.
qemu_drive "$LOG" "$ELF" "[hamsh] M16.35 shell ready" 120 \
    -- "echo DATE_BEGIN"                         2 \
       "date"                                    3 \
       "echo DATE_END"                           2 \
       "echo REALTIME_BEGIN"                     2 \
       "cat /proc/realtime"                      3 \
       "echo REALTIME_END"                       2 \
       "exit"                                    1
rc="$QEMU_DRIVE_RC"
set -e

HOST_EPOCH_AFTER=$(date -u +%s)

echo "[test_date] --- captured ---"
cat "$LOG"
echo "[test_date] --- end ---"

fail=0

# Hamsh came up.
if ! grep -F -q "[hamsh:stage-07] loop-enter" "$LOG"; then
    echo "[test_date] FAIL: hamsh never reached the interactive loop"
    fail=1
fi

# The kernel's boot-time RTC banner should also be present so we
# know rtc_init() snapshotted a real epoch (test_rtc.sh covers this
# directly; here it's a fast sanity check on the same boot).
if ! grep -E -q "rtc: boot epoch = [1-9][0-9]+" "$LOG"; then
    echo "[test_date] FAIL: kernel rtc_init banner missing / epoch=0"
    fail=1
fi

# Pull just the `date` output (between DATE_BEGIN and DATE_END).
# Strip ANSI / readline control sequences (^[[...C and ^[[K) and
# the per-keystroke "hamsh$ ..." redraws so what remains is the
# actual stdout of `date`.
date_block=$(sed -n '/DATE_BEGIN/,/DATE_END/p' "$LOG")
# `date` output: any line that looks like "YYYY-MM-DD HH:MM:SS UTC".
date_line=$(echo "$date_block" | grep -E -o "$HOST_YEAR-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2} UTC" | head -n1 || true)

if [ -z "$date_line" ]; then
    echo "[test_date] FAIL: \`date\` did not print 'YYYY-MM-DD HH:MM:SS UTC' for year=$HOST_YEAR"
    echo "[test_date]   captured DATE block:"
    echo "$date_block" | sed 's/^/[test_date]     /'
    fail=1
else
    echo "[test_date] OK: date printed '$date_line'"
fi

# Strong cross-check: /proc/realtime line 1 starts with the year too.
realtime_block=$(sed -n '/REALTIME_BEGIN/,/REALTIME_END/p' "$LOG")
realtime_iso=$(echo "$realtime_block" | grep -E -o "$HOST_YEAR-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z [0-9]+" | head -n1 || true)
if [ -z "$realtime_iso" ]; then
    echo "[test_date] FAIL: /proc/realtime line 1 did not match ISO+epoch for year=$HOST_YEAR"
    echo "[test_date]   captured REALTIME block:"
    echo "$realtime_block" | sed 's/^/[test_date]     /'
    fail=1
else
    echo "[test_date] OK: /proc/realtime line 1 = '$realtime_iso'"
fi

# Range-check the epoch against the host wall clock. We tolerate a
# 24-hour window so a slow CI run doesn't false-fail (guest could
# advance during the boot, and host clock could drift between the
# two `date` snapshots; 24h is the brief's stated tolerance).
if [ -n "$realtime_iso" ]; then
    guest_epoch=$(echo "$realtime_iso" | awk '{print $2}')
    # |guest - host| < 86400 ?
    delta=$(( guest_epoch - HOST_EPOCH_BEFORE ))
    if [ "$delta" -lt 0 ]; then delta=$(( -delta )); fi
    if [ "$delta" -gt 86400 ]; then
        echo "[test_date] FAIL: guest epoch $guest_epoch and host epoch" \
             "$HOST_EPOCH_BEFORE differ by ${delta}s (>24h tolerance)"
        fail=1
    else
        echo "[test_date] OK: guest epoch $guest_epoch within ${delta}s of host $HOST_EPOCH_BEFORE"
    fi
fi

# Sentinel: the "unavailable" path must NOT fire on a normal boot.
if echo "$date_block" | grep -F -q "RTC unavailable"; then
    echo "[test_date] FAIL: date reported RTC unavailable on a healthy boot"
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_date] FAIL (qemu rc=$rc)"
    exit 1
fi

echo "[test_date] PASS (qemu rc=$rc)"
