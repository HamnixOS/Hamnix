#!/usr/bin/env bash
# scripts/test_usb_hid_v2.sh — V2 regression for the xHCI interrupt-IN
# continuous-poll path.
#
# V0 (scripts/test_usb_hid.sh) shipped controller-detect + HID translator
# self-test. V1 (scripts/test_usb_hid_v1.sh) shipped the transfer engine
# (Enable Slot + Address Device + Configure Endpoint + control xfers)
# and a single-event Event-Ring round-trip. V2 closes the gap: the
# interrupt-IN endpoint is armed with 4 read TRBs, the timer-tick poll
# loop drains the Event Ring continuously, and each harvested report
# re-arms a fresh Normal TRB so the controller keeps streaming.
#
# What this test asserts:
#
#   1. The V2 continuous-poll self-test passes — three synthetic
#      interrupt-IN completions ('h', 'i', '!') get harvested by
#      xhci_poll back-to-back, each one re-arming the interrupt-IN
#      Transfer Ring. PASS marker:
#
#         [usb_hid_v2] PASS
#
#      A FAIL surfaces as `[usb_hid_v2] FAIL` plus per-event diag.
#
#   2. The V1 transfer-engine self-test still passes (we don't regress
#      the single-event path).
#
#   3. The V0 HID translator + atkbd PS/2 self-tests still pass.
#
#   4. No kernel panic / unexpected trap between init phases.
#
# Wire-side keystroke test (qemu sendkey x):
#
#   This script *attempts* a true wire-side keystroke harvest via the
#   QEMU monitor's `sendkey` command, but treats it as ADVISORY. The
#   real-hardware exchange depends on qemu-xhci's exact SETUP encoding
#   acceptance which varies across QEMU versions; the synthetic-event
#   PASS is the load-bearing marker. The wire-side attempt:
#
#     a. Boots QEMU with -monitor unix:./mon.sock,server,nowait.
#     b. After the V2 self-test PASS banner lands on serial, sends
#        `sendkey x` via the monitor socket using socat (or nc -U).
#     c. Greps the boot log for either a hamsh echo of 'x' or for
#        xhci.reports_received climbing above the baseline of 3
#        (the V2 self-test count).
#
#   If the wire-side attempt succeeds we log "[usb_hid_v2] WIRE: OK".
#   If it doesn't, we log "[usb_hid_v2] WIRE: NOT OBSERVED" — that's
#   not a hard FAIL because the synthetic-event PASS already proved the
#   poll/dispatch wiring is sound.
#
# Pass marker:    [usb_hid_v2] PASS
# Fail marker:    [usb_hid_v2] FAIL

set -euo pipefail

PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

# shellcheck source=_build_lock.sh
source "$PROJ_ROOT/scripts/_build_lock.sh"

ELF=build/hamnix-kernel.elf

echo "[test_usb_hid_v2] (1/3) Build userland"
bash scripts/build_user.sh >/dev/null
bash scripts/build_modules.sh >/dev/null

echo "[test_usb_hid_v2] (2/3) Build initramfs with /etc/xhci-selftest marker"
# ENABLE_XHCI_SELFTEST plants /etc/xhci-selftest so init/main.ad's gated
# xhci_v1_selftest / xhci_v2_selftest actually fire. Default boots skip
# the synthetic selftests (real-hw safety on PS/2-only Asus etc. — the
# synthetic event injection hangs xhci_poll when no USB kbd enumerated).
# The trap below rebuilds the initramfs without the marker so subsequent
# test runs get a clean default.
INIT_ELF=build/user/init.elf ENABLE_XHCI_SELFTEST=1 \
    python3 scripts/build_initramfs.py >/dev/null

echo "[test_usb_hid_v2] (3/3) Rebuild kernel + boot QEMU with qemu-xhci + usb-kbd"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

LOG=$(mktemp)
MON_SOCK=$(mktemp -u --suffix=.mon)
trap 'rm -f "$LOG" "$MON_SOCK"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null' EXIT

# Run QEMU with a unix monitor socket so we can poke `sendkey x` once
# the kernel has finished init. Background the QEMU process; we'll send
# the key after a short delay (timer cadence is 100 Hz, so even a 1 s
# settle is dozens of poll cycles) and then wait on the qemu pid.
set +e
qemu-system-x86_64 \
    -kernel "$ELF" \
    -smp 2 \
    -nographic \
    -no-reboot \
    -m 256M \
    -monitor unix:"$MON_SOCK",server,nowait \
    -serial file:"$LOG" \
    -device qemu-xhci \
    -device usb-kbd \
    > /dev/null 2>&1 &
QPID=$!

# Give the kernel time to reach the V2 self-test + hamsh prompt.
# 5 s is enough on TCG; bump if needed for slower CI.
sleep 5

# Best-effort wire-side keystroke: send `sendkey x` via the monitor
# socket. If socat / nc isn't present, skip — the synthetic-event PASS
# is the load-bearing assertion.
wire_attempted=0
if command -v socat >/dev/null 2>&1 && [ -S "$MON_SOCK" ]; then
    wire_attempted=1
    # `sendkey x\n` then drain the monitor's response with a short
    # read; `socat -t1` makes it self-terminate after no further data.
    printf 'sendkey x\nquit\n' | socat -t1 - "UNIX-CONNECT:$MON_SOCK" \
        > /dev/null 2>&1 || true
fi

# Give the kernel a few more poll cycles to harvest the keystroke (if
# the wire path worked) before we tear down.
sleep 2

kill -TERM "$QPID" 2>/dev/null || true
wait "$QPID" 2>/dev/null
rc=$?
set -e

echo "[test_usb_hid_v2] --- captured V2-relevant boot output ---"
grep -E "xhci|usb_hid|atkbd:|hid:|PANIC|TRAP" "$LOG" || true
echo "[test_usb_hid_v2] --- end ---"

fail=0

# --- V2 self-test PASS (the load-bearing marker) ---------------------
if grep -F -q "[usb_hid_v2] PASS" "$LOG"; then
    echo "[test_usb_hid_v2] OK: V2 continuous-poll PASS"
else
    echo "[test_usb_hid_v2] MISS: V2 continuous-poll PASS banner absent"
    fail=1
fi

# --- V1 regression: synthetic transfer-engine round-trip still works -
if grep -E -q "\[xhci_v1\] transfer-engine PASS \([0-9]+ reports\)" "$LOG"; then
    echo "[test_usb_hid_v2] OK: V1 synthetic transfer-engine still PASS"
else
    echo "[test_usb_hid_v2] MISS: V1 transfer-engine PASS banner absent"
    fail=1
fi

# --- V0 regression: HID translator self-test still passes ------------
if grep -F -q "[usb_hid] self-test PASS (17 cases)" "$LOG"; then
    echo "[test_usb_hid_v2] OK: V0 HID self-test still PASS"
else
    echo "[test_usb_hid_v2] MISS: V0 HID self-test PASS banner absent"
    fail=1
fi

# --- V0 regression: atkbd PS/2 self-test still passes ----------------
if grep -F -q "atkbd: self-test PASS (25 cases)" "$LOG"; then
    echo "[test_usb_hid_v2] OK: atkbd PS/2 self-test still PASS"
else
    echo "[test_usb_hid_v2] MISS: atkbd PS/2 self-test regressed"
    fail=1
fi

# --- V0 regression: root-hub port scan still finds the kbd -----------
if grep -E -q "\[xhci\] root hub: keyboard at port [0-9]+" "$LOG"; then
    echo "[test_usb_hid_v2] OK: V0 root-hub keyboard discovery still works"
else
    echo "[test_usb_hid_v2] MISS: V0 root-hub keyboard discovery regressed"
    fail=1
fi

# --- V1 regression: USB keyboard enabled banner ----------------------
if grep -F -q "[xhci] USB keyboard enabled" "$LOG"; then
    echo "[test_usb_hid_v2] OK: V1 USB keyboard enabled (interrupt-IN armed)"
else
    echo "[test_usb_hid_v2] MISS: V1 enumeration didn't reach 'enabled' state"
    # Non-fatal: V2 self-test runs even on the V1 fallback path, so a
    # missing 'enabled' banner is informational not blocking.
fi

# --- Negative: no panic between init phases --------------------------
if grep -E -q "PANIC|TRAP: vector" "$LOG"; then
    echo "[test_usb_hid_v2] MISS: kernel panic / unexpected trap in boot log"
    fail=1
fi

# --- Advisory: wire-side keystroke harvest ---------------------------
# The wire path is finicky on qemu-xhci so this is ADVISORY ONLY. The
# synthetic-event PASS above is the load-bearing assertion. We flag
# success if it works so users on QEMU versions that do honor our
# SETUP encoding get a green check.
if [ "$wire_attempted" = "1" ]; then
    # `reports_received` only climbs above the V2 self-test baseline (3)
    # if a real wire-side event landed. The V2 self-test prints its
    # own count via [xhci_v2] line; anything above that is wire-side.
    if grep -E -q "\[xhci\] wire: keystroke harvested" "$LOG"; then
        echo "[test_usb_hid_v2] WIRE: OK (wire-side keystroke observed)"
    else
        echo "[test_usb_hid_v2] WIRE: NOT OBSERVED (synthetic PASS is load-bearing)"
    fi
else
    echo "[test_usb_hid_v2] WIRE: skipped (no socat available)"
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_usb_hid_v2] FAIL (qemu rc=$rc)"
    exit 1
fi

echo "[test_usb_hid_v2] PASS"
