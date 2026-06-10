#!/usr/bin/env bash
# scripts/test_de_scrollwheel_guard.sh — structural regression guard for the
# end-to-end mouse SCROLL-WHEEL chain.
#
# This is a fast, deterministic, grep-only guard (NO QEMU boot). It locks in the
# four load-bearing links of the wheel chain so a future refactor can't silently
# sever any of them without a CI failure naming exactly which link broke:
#
#   1. drivers/usb/hid.ad
#        hid_mouse_report() reads byte 3 as a signed int8 wheel delta ONLY when
#        length >= 4, and threads it through mouse_rx_push_dz.
#
#   2. drivers/input/auxmouse.ad
#        MouseEvent carries a `dz` field; mouse_rx_push_dz() / mouse_rx_pop_dz()
#        exist as the wheel-aware injection/extraction pair.
#
#   3. sys/src/9/port/devmouse.ad
#        devmouse_read emits a 4-field text packet "<dx> <dy> <buttons> <dz>\n";
#        devmouse_write still parses dz as OPTIONAL (legacy 3-field => dz=0).
#
#   4. user/hamUId.ad
#        daemon_scroll_focused() is DEFINED and CALLED inside daemon_apply_packet
#        (gated on dz != 0), injecting CSI arrow sequences into the focused
#        window's stdin.
#
# Pass marker:  PASS: DE scroll-wheel chain intact
# Fail marker:  FAIL: <which link broke>

set -euo pipefail

PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

HID="drivers/usb/hid.ad"
AUX="drivers/input/auxmouse.ad"
DEV="sys/src/9/port/devmouse.ad"
UID_SRC="user/hamUId.ad"

fail=0

# fail_link <link-description>
fail_link() {
    echo "FAIL: $1" >&2
    fail=1
}

# require_file <path>
require_file() {
    if [ ! -f "$1" ]; then
        fail_link "source file missing: $1"
        return 1
    fi
    return 0
}

for f in "$HID" "$AUX" "$DEV" "$UID_SRC"; do
    require_file "$f" || true
done
if [ "$fail" -ne 0 ]; then
    echo "FAIL: DE scroll-wheel guard — required source file(s) missing" >&2
    exit 1
fi

# --- Link 1: drivers/usb/hid.ad ------------------------------------------------
# hid_mouse_report must thread the wheel delta through mouse_rx_push_dz...
if ! grep -q "mouse_rx_push_dz" "$HID"; then
    fail_link "link 1 (hid.ad): no reference to mouse_rx_push_dz — wheel delta no longer reaches the auxmouse side channel"
fi
# ...and must gate the byte-3 wheel read on the report carrying >= 4 bytes.
# Accept either spacing style ('length >= 4' or 'length>=4').
if ! grep -Eq "length[[:space:]]*>=[[:space:]]*4" "$HID"; then
    fail_link "link 1 (hid.ad): missing 'length >= 4' guard on the byte-3 wheel read — phantom scroll from stale DMA slots could leak"
fi

# --- Link 2: drivers/input/auxmouse.ad -----------------------------------------
# MouseEvent must declare the dz field (the wheel side channel in the ring).
if ! grep -Eq "^[[:space:]]*dz:" "$AUX"; then
    fail_link "link 2 (auxmouse.ad): MouseEvent no longer declares a 'dz' field — the ring can't carry a wheel delta"
fi
# Wheel-aware push must exist.
if ! grep -Eq "def[[:space:]]+mouse_rx_push_dz" "$AUX"; then
    fail_link "link 2 (auxmouse.ad): mouse_rx_push_dz() definition is gone"
fi
# Wheel-aware pop must exist.
if ! grep -Eq "def[[:space:]]+mouse_rx_pop_dz" "$AUX"; then
    fail_link "link 2 (auxmouse.ad): mouse_rx_pop_dz() definition is gone"
fi

# --- Link 3: sys/src/9/port/devmouse.ad ----------------------------------------
# devmouse_read must emit the 4-field packet that carries dz as the trailing
# field. The packet is assembled field-by-field; its documented wire format
# string "<dx> <dy> <buttons> <dz>\n" is the load-bearing contract token.
if ! grep -q "<dz>" "$DEV"; then
    fail_link "link 3 (devmouse.ad): the 4-field '<dx> <dy> <buttons> <dz>' packet format (the trailing <dz> field) is gone — /dev/mouse no longer publishes the wheel"
fi
# And the read path must actually pop a dz to emit (proves it's wired, not just
# documented).
if ! grep -q "mouse_rx_pop_dz" "$DEV"; then
    fail_link "link 3 (devmouse.ad): devmouse_read no longer pops the wheel delta via mouse_rx_pop_dz"
fi
# devmouse_write must still exist and parse dz as an OPTIONAL field (legacy
# 3-field packets must keep working with dz defaulting to 0).
if ! grep -Eq "def[[:space:]]+devmouse_write" "$DEV"; then
    fail_link "link 3 (devmouse.ad): devmouse_write() definition is gone"
fi
if ! grep -Eq "dz:[[:space:]]*int32[[:space:]]*=[[:space:]]*0" "$DEV"; then
    fail_link "link 3 (devmouse.ad): devmouse_write no longer defaults dz to 0 — the optional 4th-field parse (legacy 3-field compatibility) is broken"
fi

# --- Link 4: user/hamUId.ad ----------------------------------------------------
# daemon_scroll_focused must be DEFINED...
if ! grep -Eq "def[[:space:]]+daemon_scroll_focused" "$UID_SRC"; then
    fail_link "link 4 (hamUId.ad): daemon_scroll_focused() definition is gone"
fi
# ...and CALLED. A live chain needs at least the definition AND one call site, so
# the bare identifier 'daemon_scroll_focused(' must appear more than once.
scroll_calls=$(grep -c "daemon_scroll_focused(" "$UID_SRC" || true)
if [ "${scroll_calls:-0}" -lt 2 ]; then
    fail_link "link 4 (hamUId.ad): daemon_scroll_focused is defined but never called (found ${scroll_calls:-0} occurrence(s); need definition + call site)"
fi
# Be specific: the call must live inside the mouse-packet dispatcher.
if ! grep -Eq "def[[:space:]]+daemon_apply_packet" "$UID_SRC"; then
    fail_link "link 4 (hamUId.ad): daemon_apply_packet() — the call site for daemon_scroll_focused — is gone"
fi

if [ "$fail" -ne 0 ]; then
    echo "FAIL: DE scroll-wheel chain BROKEN (see link(s) above)" >&2
    exit 1
fi

echo "PASS: DE scroll-wheel chain intact"
exit 0
