#!/usr/bin/env bash
# scripts/test_de_drag_no_spurious_keys.sh — structural regression guard for
# the compositor's "drop keystrokes during a window drag" rule.
#
# The bug this guards against: while the user holds the title bar to MOVE a
# window (or grabs an edge to RESIZE, or sweeps the rubber-band create
# gesture), the WM owns the input. Stray characters were appearing in the
# dragged window's shell because daemon_pump_keys was routing every drained
# /dev/cons byte to the focused window with NO gating on the WM gesture
# state.
#
# Fix shape (see DE: drop keystrokes during window drag commit): a
# wm_owns_input() predicate, returning 1 whenever MOVE_SLOT/RESIZE_SLOT/
# DRAG_ACTIVE/GESTURE indicate the WM is mid-gesture; daemon_pump_keys
# drains the kernel /dev/cons ring (so it can't overflow) and DROPS the
# bytes via `continue` instead of calling key_process_chunk. The
# wheel-synth path (daemon_scroll_focused) is gated by the same predicate
# so a stray scroll notch can't inject ESC[A/B into the dragged shell.
#
# This is a fast, deterministic, grep-only guard (NO QEMU boot). It pins
# the load-bearing links so a future refactor can't silently sever them.
#
# Pass marker:  PASS: DE drag keystroke gate intact
# Fail marker:  FAIL: <which link broke>

set -euo pipefail

PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

UID_SRC="user/hamUId.ad"

fail=0

fail_link() {
    echo "FAIL: $1" >&2
    fail=1
}

if [ ! -f "$UID_SRC" ]; then
    echo "FAIL: source file missing: $UID_SRC" >&2
    exit 1
fi

# --- Link 1: the gate PREDICATE wm_owns_input must be DEFINED. ----------------
if ! grep -Eq "def[[:space:]]+wm_owns_input" "$UID_SRC"; then
    fail_link "link 1: wm_owns_input() predicate is gone — no way to detect a WM-owned drag"
fi

# --- Link 2: the predicate must observe all four drag states. ----------------
# Pull the body of wm_owns_input (def line through the next blank-line/def).
gate_body=$(awk '
    /^def[[:space:]]+wm_owns_input/ { capturing = 1; next }
    capturing && /^def[[:space:]]/ { exit }
    capturing { print }
' "$UID_SRC")

for var in "MOVE_SLOT" "RESIZE_SLOT" "DRAG_ACTIVE" "GESTURE"; do
    if ! grep -q "$var" <<<"$gate_body"; then
        fail_link "link 2: wm_owns_input() no longer observes $var — a $var drag will leak keys to the focused window"
    fi
done

# --- Link 3: daemon_pump_keys must CALL the gate, and DROP (continue/break/
# skip the key_process_chunk call) when it returns nonzero. -------------------
if ! grep -Eq "def[[:space:]]+daemon_pump_keys" "$UID_SRC"; then
    fail_link "link 3: daemon_pump_keys() is gone — no /dev/cons drain"
fi

pump_body=$(awk '
    /^def[[:space:]]+daemon_pump_keys/ { capturing = 1; next }
    capturing && /^def[[:space:]]/ { exit }
    capturing { print }
' "$UID_SRC")

if ! grep -q "wm_owns_input" <<<"$pump_body"; then
    fail_link "link 3: daemon_pump_keys no longer consults wm_owns_input — drag-time keystrokes will reach the focused shell"
fi

# The gate must be wired as a CONDITIONAL that skips the routing call. We
# accept either `continue` or `break` after the wm_owns_input check, as long
# as it appears BEFORE the key_process_chunk call.
gate_line=$(grep -n "wm_owns_input" <<<"$pump_body" | head -1 | cut -d: -f1 || true)
kpc_line=$(grep -n "key_process_chunk" <<<"$pump_body" | head -1 | cut -d: -f1 || true)
if [ -z "$gate_line" ] || [ -z "$kpc_line" ]; then
    fail_link "link 3: daemon_pump_keys is missing either the gate check or the key_process_chunk call"
elif [ "$gate_line" -ge "$kpc_line" ]; then
    fail_link "link 3: wm_owns_input check sits AFTER key_process_chunk in daemon_pump_keys — keystrokes route before the gate fires"
fi

# Must also have a control-flow keyword that ACTUALLY drops the byte run
# (continue/break/return) somewhere in the pump body — otherwise the gate
# is decorative.
if ! grep -Eq "(continue|break|return)" <<<"$pump_body"; then
    fail_link "link 3: daemon_pump_keys has no continue/break/return — the gate cannot actually drop the drained bytes"
fi

# --- Link 4: daemon_scroll_focused must also consult the gate, so a stray
# wheel notch during a drag can't synthesize ESC[A/B keystrokes into the
# dragged shell. -------------------------------------------------------------
scroll_body=$(awk '
    /^def[[:space:]]+daemon_scroll_focused/ { capturing = 1; next }
    capturing && /^def[[:space:]]/ { exit }
    capturing { print }
' "$UID_SRC")

if ! grep -q "wm_owns_input" <<<"$scroll_body"; then
    fail_link "link 4: daemon_scroll_focused no longer consults wm_owns_input — wheel-synth ESC[A/B can leak into the dragged shell"
fi

if [ "$fail" -ne 0 ]; then
    echo "FAIL: DE drag keystroke gate BROKEN (see link(s) above)" >&2
    exit 1
fi

echo "PASS: DE drag keystroke gate intact"
exit 0
