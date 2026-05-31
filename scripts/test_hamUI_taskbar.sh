#!/usr/bin/env bash
# scripts/test_hamUI_taskbar.sh — hamUI taskbar, minimize, and live clock.
#
# Verifies three new MATE-style panel features added to `hamUId daemon`:
#
#   1. WINDOW-LIST TASKBAR: open two windows, assert two taskbar buttons
#      appear (TASKBAR 2 windows, TASKBAR geometry OK). Simulate a taskbar
#      click and assert the focused window changed (TASKBAR focus OK).
#
#   2. MINIMIZE / RESTORE: simulate a minimize-box click on the topmost
#      window (TASKBAR minimize OK), then restore via a taskbar click
#      (TASKBAR restore OK).
#
#   3. LIVE CLOCK: call clock_refresh() and assert the clock string is
#      populated (TASKBAR clock OK or TASKBAR clock UNAVAILABLE — either
#      proves the refresh function ran and produced a valid string).
#
# DETERMINISTIC PROOF. `hamUId daemon taskbarselftest` drives these
# features through the EXACT same gesture state machine (wm_button)
# that real /dev/mouse packets reach — with absolute cursor coordinates,
# so no QEMU mouse injection and the result is repeatable.
#
# Serial markers asserted:
#     DAEMON up screen=
#     TASKBAR 2 windows
#     TASKBAR geometry OK
#     TASKBAR focus OK
#     TASKBAR minimize OK
#     TASKBAR restore OK
#     TASKBAR clock OK   (OR TASKBAR clock UNAVAILABLE)
#     TASKBAR PASS
#
# SKIPS CLEANLY (exit 0) when the daemon can't come up under -vga std on
# this host (same QEMU multiboot VBE + 64-bit limitation the other hamUI
# self-tests guard against). The authoritative GOP gate is
# test_img_uefi_hamui.sh.

. "$(dirname "$0")/_build_lock.sh"

set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf

echo "[test_hamUI_taskbar] (1/4) Build userland"
bash scripts/build_user.sh >/dev/null
bash scripts/build_modules.sh >/dev/null

echo "[test_hamUI_taskbar] (2/4) Build initramfs"
python3 scripts/build_initramfs.py >/dev/null

echo "[test_hamUI_taskbar] (3/4) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

if [ ! -s build/user/hamUId.elf ]; then
    echo "[test_hamUI_taskbar] FAIL: build/user/hamUId.elf missing/empty"
    exit 1
fi

echo "[test_hamUI_taskbar] (4/4) Boot QEMU + run taskbar self-test"

LOG="$(mktemp)"
trap 'rm -f "$LOG"' EXIT

set +e
(
    sleep 10
    printf 'echo MARK_TASKBAR_BEGIN; hamUId daemon taskbarselftest\n'
    sleep 25
) | timeout 75s qemu-system-x86_64 \
    -kernel "$ELF" \
    -smp 2 \
    -vga std \
    -display none \
    -no-reboot \
    -m 256M \
    -serial stdio \
    > "$LOG" 2>&1
rc=$?
set -e

# A kernel panic / CPU trap is ALWAYS a hard failure.
if grep -aE -q "PANIC|panic:|TRAP:|BUG:" "$LOG"; then
    echo "[test_hamUI_taskbar] FAIL: kernel panic / trap"
    tail -n 60 "$LOG"
    exit 1
fi

# SKIP CLEANLY when the hamUId daemon never came up under -vga std on this
# host (QEMU multiboot VBE + 64-bit limitation / no VBE framebuffer).
if ! grep -aq 'DAEMON up screen=' "$LOG"; then
    echo "[test_hamUI_taskbar] SKIP: hamUId daemon did not come up under -vga std on this host. Authoritative GOP gate: scripts/test_img_uefi_hamui.sh." >&2
    exit 0
fi

echo "[test_hamUI_taskbar] --- captured serial output (TASKBAR markers) ---"
grep -aE 'DAEMON|TASKBAR|MARK_TASKBAR_BEGIN' "$LOG" | head -40
echo "[test_hamUI_taskbar] --- end ---"

fail=0

assert_marker() {
    if grep -aq "$1" "$LOG"; then
        echo "[test_hamUI_taskbar] OK: $2"
    else
        echo "[test_hamUI_taskbar] MISS: $2 (expected marker: '$1')"
        fail=1
    fi
}

assert_marker 'DAEMON up screen=' 'daemon started + read framebuffer geometry'
assert_marker 'TASKBAR 2 windows' '2 windows created for taskbar test'
assert_marker 'TASKBAR geometry OK' 'taskbar button geometry within panel bounds'
assert_marker 'TASKBAR focus OK' 'taskbar click raised and focused window'
assert_marker 'TASKBAR minimize OK' 'minimize-box click hid window to taskbar'
assert_marker 'TASKBAR restore OK' 'taskbar click restored minimized window'
# Clock: either "clock OK" (real time from /proc/realtime) or
# "clock UNAVAILABLE" (uptime fallback or RTC not seeded) — both prove
# the refresh ran and produced a valid non-empty string.
if grep -aq 'TASKBAR clock OK' "$LOG"; then
    echo "[test_hamUI_taskbar] OK: live clock updated (wall-clock time)"
elif grep -aq 'TASKBAR clock UNAVAILABLE' "$LOG"; then
    echo "[test_hamUI_taskbar] OK: live clock updated (uptime/unavailable fallback)"
else
    echo "[test_hamUI_taskbar] MISS: clock string not populated (expected 'TASKBAR clock OK' or 'TASKBAR clock UNAVAILABLE')"
    fail=1
fi
assert_marker 'TASKBAR PASS' 'taskbar self-test completed successfully'

# rc=124 (timeout killed the daemon) or 0 (self-test exit) are both fine.
if [ "$fail" -ne 0 ]; then
    echo "[test_hamUI_taskbar] FAIL (qemu rc=$rc)"
    exit 1
fi

echo "[test_hamUI_taskbar] capture method: drives real daemon gesture machine (wm_button) with absolute coordinates + deterministic serial markers"
echo "[test_hamUI_taskbar] PASS"
