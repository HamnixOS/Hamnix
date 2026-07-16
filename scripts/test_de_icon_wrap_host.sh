#!/usr/bin/env bash
# scripts/test_de_icon_wrap_host.sh — host structural + arithmetic guard for the
# desktop-icon COLUMN-WRAP fix (fix/desktop-icon-column-wrap).
#
# Bug: with 12 shipped desktop icons (etc/skel/Desktop/) laid out in a single
# fixed left column at CELL_H=72 from ICON_TOP=16, the 12th icon (Video Player,
# sorts last) fell OFF the bottom of a 768px screen and the user could not see
# it ("I don't see a video player"). The fix wraps the default flow into extra
# columns once a cell would fall under the bottom panel / off-screen.
#
# This gate (no QEMU):
#   1. Confirms user/hamdesktop.ad grows the wrapping layout (icons_per_col()
#      helper; icon_cx uses col*CELL_W; icon_cy uses row + icons_per_col).
#   2. Re-derives the layout arithmetic from the ACTUAL constants in the source
#      and asserts that on a standard 768px-tall screen ALL 12 icons — including
#      the 12th — have a cell whose bottom is on-screen (<= scr_h - bottom
#      panel), i.e. nothing is clipped by the bottom panel or the screen edge.
#   3. Asserts the single-column look is preserved when few icons fit (all in
#      column 0).
#
# Pass marker:  PASS: desktop icon column-wrap keeps all 12 icons on-screen
# Fail marker:  FAIL: <what broke>

set -euo pipefail

PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

SRC="user/hamdesktop.ad"

fail=0
bad() { echo "FAIL: $1" >&2; fail=1; }

[ -f "$SRC" ] || { echo "FAIL: $SRC missing" >&2; exit 1; }

# --- Link 1: the wrapping layout is present in source --------------------
grep -qE '^def[[:space:]]+icons_per_col[[:space:]]*\(' "$SRC" \
    || bad "icons_per_col() helper missing (no column-wrap)"
grep -qE 'col[[:space:]]*\*[[:space:]]*CELL_W' "$SRC" \
    || bad "icon_cx no longer offsets columns by CELL_W"
grep -qE '%[[:space:]]*icons_per_col\(\)' "$SRC" \
    || bad "icon_cy no longer wraps rows via icons_per_col()"

# --- Extract the actual layout constants from source ---------------------
val() {  # val NAME  -> integer value of a top-level `NAME: intNN = <num>` decl
    awk -v n="$1" '
        $0 ~ ("^" n "[[:space:]]*:") {
            for (i=1;i<=NF;i++) if ($i=="=") { gsub(/[^0-9-]/,"",$(i+1)); print $(i+1); exit }
        }' "$SRC"
}
ICON_TOP=$(val ICON_TOP)
CELL_H=$(val CELL_H)
CELL_W=$(val CELL_W)
ICON_INSET_Y=$(val ICON_INSET_Y)
ICON_H=$(val ICON_H)
PANEL_BOT_H=$(val PANEL_BOT_H)
ICON_MARGIN_X=$(val ICON_MARGIN_X)

for v in ICON_TOP CELL_H CELL_W ICON_INSET_Y ICON_H PANEL_BOT_H ICON_MARGIN_X; do
    [ -n "${!v}" ] || bad "could not read constant $v from $SRC"
done
[ "$fail" -eq 0 ] || { echo "FAIL: constant extraction failed" >&2; exit 1; }

# --- Re-derive the layout (mirrors icon_cx/icon_cy/icons_per_col) --------
SCR_H=768                 # standard shipped screen height
N_ICONS=12                # audioplayer video calculator terminal files editor
                          # notes calendar control-center sysmon logviewer installer
USABLE_BOTTOM=$(( SCR_H - PANEL_BOT_H ))
PER_COL=$(( (SCR_H - PANEL_BOT_H - ICON_TOP) / CELL_H ))
[ "$PER_COL" -ge 1 ] || PER_COL=1
echo "info: scr_h=$SCR_H per_col=$PER_COL usable_bottom=$USABLE_BOTTOM (12 icons)"

# Every icon's cell bottom must be on-screen (not under the bottom panel).
i=0
while [ "$i" -lt "$N_ICONS" ]; do
    row=$(( i % PER_COL ))
    col=$(( i / PER_COL ))
    cy=$(( ICON_TOP + row * CELL_H ))
    cx=$(( ICON_MARGIN_X + col * CELL_W ))
    icon_bottom=$(( cy + ICON_INSET_Y + ICON_H ))
    if [ "$icon_bottom" -gt "$USABLE_BOTTOM" ]; then
        bad "icon #$i clipped: cell cy=$cy bottom=$icon_bottom > usable=$USABLE_BOTTOM (col=$col row=$row)"
    fi
    i=$(( i + 1 ))
done

# The 12th icon (index 11, Video Player) specifically must be visible + wrapped.
row11=$(( 11 % PER_COL )); col11=$(( 11 / PER_COL ))
cy11=$(( ICON_TOP + row11 * CELL_H ))
bot11=$(( cy11 + ICON_INSET_Y + ICON_H ))
[ "$col11" -ge 1 ] || bad "12th icon did not wrap into a 2nd column (col=$col11)"
[ "$bot11" -le "$USABLE_BOTTOM" ] || bad "12th icon (Video Player) clipped: bottom=$bot11 > $USABLE_BOTTOM"
echo "info: 12th icon -> col=$col11 row=$row11 cy=$cy11 bottom=$bot11 (<= $USABLE_BOTTOM)"

# --- Single-column look preserved when few icons fit ---------------------
few=5
j=0
while [ "$j" -lt "$few" ]; do
    col=$(( j / PER_COL ))
    [ "$col" -eq 0 ] || bad "few-icon layout regressed to multi-column (icon $j col=$col)"
    j=$(( j + 1 ))
done

if [ "$fail" -ne 0 ]; then
    echo "FAIL: desktop icon column-wrap gate failed" >&2
    exit 1
fi
echo "PASS: desktop icon column-wrap keeps all 12 icons on-screen"
