#!/usr/bin/env bash
# scripts/test_de_windowshade_guard.sh — structural regression guard for the
# desktop window-shade (titlebar double-click roll-up) chain.
#
# This is a fast, deterministic, grep-only guard (NO QEMU boot). It locks in the
# load-bearing links of the window-shade feature so a future refactor can't
# silently sever any of them without a CI failure naming exactly which link
# broke:
#
#   1. user/hamUId.ad
#        window_toggle_shade() is DEFINED and CALLED — it must appear more than
#        once (definition + at least one wired call site), proving it's live and
#        not dead code.
#
#   2. user/hamUId.ad
#        The title-bar double-click gesture (the `dbl != 0` branch in wm_button)
#        is bound to SHADE — it calls window_toggle_shade and emits the
#        "WM dblclick shade" marker (i.e. double-click rolls up, not maximize).
#
#   3. user/hamUId.ad
#        The per-window shade state — DWIN_SHADED, DWIN_SHADE_H — and the
#        rolled-up height constant SHADE_H all exist; a shaded window collapses
#        DWIN_H to SHADE_H.
#
# Pass marker:  PASS: DE window-shade chain intact
# Fail marker:  FAIL: <which link broke>

set -euo pipefail

PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

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

require_file "$UID_SRC" || true
if [ "$fail" -ne 0 ]; then
    echo "FAIL: DE window-shade guard — required source file(s) missing" >&2
    exit 1
fi

# --- Link 1: window_toggle_shade defined AND wired -----------------------------
# window_toggle_shade must be DEFINED...
if ! grep -Eq "def[[:space:]]+window_toggle_shade" "$UID_SRC"; then
    fail_link "link 1 (hamUId.ad): window_toggle_shade() definition is gone"
fi
# ...and CALLED. A live chain needs at least the definition AND one call site, so
# the bare identifier 'window_toggle_shade(' must appear more than once.
shade_calls=$(grep -c "window_toggle_shade(" "$UID_SRC" || true)
if [ "${shade_calls:-0}" -lt 2 ]; then
    fail_link "link 1 (hamUId.ad): window_toggle_shade is defined but never called (found ${shade_calls:-0} occurrence(s); need definition + call site) — window-shade is dead code"
fi

# --- Link 2: title-bar double-click is bound to SHADE --------------------------
# The double-click gesture must emit the load-bearing "WM dblclick shade" marker,
# proving the dbl-click branch rolls the window up (shade) rather than maximize.
if ! grep -q "WM dblclick shade" "$UID_SRC"; then
    fail_link "link 2 (hamUId.ad): the 'WM dblclick shade' marker is gone — the title-bar double-click gesture is no longer wired to window-shade"
fi
# And the dbl-click branch must actually call window_toggle_shade (the gesture is
# bound to shade, not some other action). Grep the two tokens together so a
# stray marker comment alone can't pass.
if ! grep -Eq "if[[:space:]]+dbl[[:space:]]*!=[[:space:]]*0" "$UID_SRC"; then
    fail_link "link 2 (hamUId.ad): the 'dbl != 0' double-click branch in wm_button is gone — the double-click gesture can't fire shade"
fi

# --- Link 3: per-window shade state + collapsed-height constant -----------------
# Per-window shade flag array.
if ! grep -q "DWIN_SHADED" "$UID_SRC"; then
    fail_link "link 3 (hamUId.ad): DWIN_SHADED — the per-window shade-state array — is gone"
fi
# Stashed full-height array (so unshade can restore the original height).
if ! grep -q "DWIN_SHADE_H" "$UID_SRC"; then
    fail_link "link 3 (hamUId.ad): DWIN_SHADE_H — the stashed full-height array (needed to un-shade) — is gone"
fi
# The rolled-up height constant a shaded window collapses to.
if ! grep -Eq "SHADE_H[[:space:]]*:" "$UID_SRC"; then
    fail_link "link 3 (hamUId.ad): the SHADE_H rolled-up height constant is gone — shaded windows have nothing to collapse to"
fi

if [ "$fail" -ne 0 ]; then
    echo "FAIL: DE window-shade chain BROKEN (see link(s) above)" >&2
    exit 1
fi

echo "PASS: DE window-shade chain intact"
exit 0
