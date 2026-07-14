#!/usr/bin/env bash
# scripts/test_de_term_editor_features.sh — REGRESSION gate for three DE
# terminal / shell interactivity features that can each silently rot
# across unrelated refactors:
#
#   1. Mid-line cursor editing via arrow keys.   The shell line editor
#      (user/hamsh.ad ed_readline) parses ANSI escape sequences (ESC [ D /
#      ESC [ C / ESC [ H / ESC [ F / ESC [ 3~) and inserts/deletes at an
#      in-line cursor; the DE terminal (user/hamtermscene.ad) must FORWARD
#      the leading ESC byte (27, a control byte) to the shell or the
#      sequence is broken into literal "[D" text.
#
#   2. Up/Down command history.   ed_readline keeps a ring of entered lines
#      (hist_buf / hist_append) and Up/Down (ESC [ A / ESC [ B) recall it.
#
#   3. Mouse-wheel scrollback.   the in-kernel pointer router delivers the
#      "m <x> <y> <buttons> <dz>" line on /dev/wsys/<wid>/event (NOT the
#      separate /pointer file, which only the userland-compositor path uses).
#      hamtermscene reads /event, mines the wheel-notch (dz) field, and drives
#      a retained scrollback history ring (sb_rows) through a view offset
#      (term_view_off). hameditscene mines the same /event dz to scroll
#      top_line. (The earlier /pointer wiring was a dead path — the router
#      never wrote it — which is why the wheel did nothing.)
#
# These are USERSPACE line-editor / glyph-grid behaviours with no clean
# in-VM injection point that isn't itself flaky (key/mouse fixtures need a
# QMP socket that conflicts with -serial stdio; see test_atkbd_ext.sh's
# rationale). So this gate locks down the load-bearing MACHINERY at the
# source plus a standalone clean compile of both binaries — the same
# strategy test_de_term_render_nokey.sh uses for the command-not-found
# message. A full end-to-end VM keystroke/wheel smoke remains the manual
# follow-up; the heavy VM gates (test_de_scene_termfm,
# test_de_term_render_nokey) cover the render path.
#
# rc=124 (host-load timeout on the compile) is NOT a failure.

set -uo pipefail

PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

HAMSH="user/hamsh.ad"
HTS="user/hamtermscene.ad"
HES="user/hameditscene.ad"
fail=0

note()  { echo "[term_editor] $*"; }
pass()  { echo "[term_editor] PASS $*"; }
failf() { echo "[term_editor] FAIL $*" >&2; fail=1; }

# Require a literal substring (fixed-string) somewhere in a file.
need() { # file pattern human
    if grep -aqF -- "$2" "$1"; then pass "$3"; else failf "$3 (missing: $2 in $1)"; fi
}
# Require a regex match in a file.
needre() { # file regex human
    if grep -aqE -- "$2" "$1"; then pass "$3"; else failf "$3 (regex miss: $2 in $1)"; fi
}

note "--- (1) arrow-key mid-line editing ---"
# hamsh: escape state machine + Left/Right + insert/delete at cursor.
need   "$HAMSH" "ed_cur" "ed_readline tracks an in-line cursor position"
needre "$HAMSH" "ed_esc_state == 2" "ed_readline parses CSI escape sequences"
needre "$HAMSH" "c == 68" "ed_readline handles Left arrow (ESC [ D)"
needre "$HAMSH" "c == 67" "ed_readline handles Right arrow (ESC [ C)"
need   "$HAMSH" "_ed_insert_at_cursor" "printable bytes insert at the cursor"
need   "$HAMSH" "_ed_delete_at_cursor" "Backspace/Delete remove at the cursor"
# hamtermscene MUST forward the ESC byte (control byte 27), not just
# printable + Enter + Backspace — else the arrow sequence is broken.
needre "$HTS"   "code >= 1 and code < 127" \
    "hamtermscene forwards control bytes (incl. ESC=27) to the shell stdin"

note "--- (1b) visible '_' cursor tracks the edit caret column ---"
# REGRESSION (hands-on QA): arrow keys moved the edit position but the
# underscore cursor indicator stayed pinned to the END of the line. Root
# cause was _paint_scene appending the '_' at rlen unconditionally instead
# of drawing it at the caret column. _redraw_edit_line already parks the
# streaming cursor (term_col) at the in-line caret; the paint must overlay
# the '_' at that column, and only APPEND it past the text when the caret
# sits at end-of-line.
needre "$HTS" "cur_col: uint64 = term_col" \
    "_paint_scene reads the caret column from term_col (the parked edit caret)"
needre "$HTS" "k == cur_col" \
    "the '_' cursor overlays the glyph at the caret column (mid-line tracking)"
needre "$HTS" "cur_col >= rlen" \
    "the '_' is only appended past the text when the caret is at end-of-line"
# _redraw_edit_line must keep parking term_col at the caret so the overlay
# column is correct after Left/Right/Home/End/insert/delete.
needre "$HTS" "term_col = edit_base \+ \(term_line_cur - start\)" \
    "_redraw_edit_line parks term_col at the in-line edit caret"

note "--- (2) command history (Up/Down) ---"
need   "$HAMSH" "hist_append" "history ring append exists"
need   "$HAMSH" "_hist_load"  "history recall loads a stored line"
needre "$HAMSH" "c == 65" "Up arrow (ESC [ A) walks to older history"
needre "$HAMSH" "c == 66" "Down arrow (ESC [ B) walks to newer history"
# The completed line is pushed into history after Enter.
needre "$HAMSH" "hist_append\(&ed_buf\[0\]" "entered line is pushed to history"

note "--- (3) mouse-wheel scrollback (terminal) ---"
# The wheel notch rides the "m ... <dz>" line on /event (the router pushes
# pointer lines onto the EVENT ring); the term must read /event and mine dz.
need   "$HTS" "/event" "hamtermscene opens the /event stream (carries the wheel dz)"
need   "$HTS" "_evt_apply_wheel" "the /event 'm' line is parsed for the wheel notch (dz)"
needre "$HTS" "if t == 109" "the /event drain handles the 'm' (109) pointer line"
need   "$HTS" "term_view_off" "a scrollback view offset exists"
need   "$HTS" "sb_rows" "a retained scrollback history ring exists"
need   "$HTS" "_sb_push" "rows scrolled off the top are pushed into history"
needre "$HTS" "_grid_hash" "the view offset is folded into the grid hash (re-commit on scroll)"
# Wheel handling: dz>0 older, dz<0 toward tail, clamped; typing snaps back.
need   "$HTS" "_scroll_by" "wheel notches adjust the scrollback view (clamped)"
needre "$HTS" "term_view_off = 0" "typing snaps the view back to the live tail"
# The dead /pointer wiring must NOT come back (that was the root-cause bug):
# no _winpath(...,"/pointer") and no /pointer sys_open. (Comments may still
# mention /pointer to explain WHY it is unused, so match the wiring, not text.)
if grep -aqE '_winpath\([^)]*"/pointer"|sys_open\([^)]*pointer' "$HTS"; then
    failf "hamtermscene must NOT open /pointer (dead path; wheel rides /event)"
else
    pass "hamtermscene no longer opens the dead /pointer file"
fi

note "--- (3b) mouse-wheel scroll (editor) ---"
need   "$HES" "/event" "hameditscene opens the /event stream (carries the wheel dz)"
need   "$HES" "_ed_scroll_by" "editor wheel notches scroll the text viewport (top_line)"
needre "$HES" "ed_evbuf\[ls\] == 109" "the editor /event drain handles the 'm' (109) wheel line"
need   "$HES" "top_line" "editor vertical scroll offset (top_line) exists"

note "--- (4) clean standalone compile of both binaries ---"
ADDER="python3 -m compiler.adder compile --target=x86_64-adder-user"
TMP_HAMSH=$(mktemp --tmpdir te-hamsh.XXXXXX.elf)
TMP_HTS=$(mktemp --tmpdir te-hts.XXXXXX.elf)
TMP_HES=$(mktemp --tmpdir te-hes.XXXXXX.elf)
cleanup() { rm -f "$TMP_HAMSH" "$TMP_HTS" "$TMP_HES"; }
trap cleanup EXIT

if $ADDER "$HAMSH" -o "$TMP_HAMSH" >/dev/null 2>&1; then
    pass "user/hamsh.ad compiles"
else
    failf "user/hamsh.ad failed to compile"
fi
if $ADDER "$HTS" -o "$TMP_HTS" >/dev/null 2>&1; then
    pass "user/hamtermscene.ad compiles"
else
    failf "user/hamtermscene.ad failed to compile"
fi
if $ADDER "$HES" -o "$TMP_HES" >/dev/null 2>&1; then
    pass "user/hameditscene.ad compiles"
else
    failf "user/hameditscene.ad failed to compile"
fi

echo "[term_editor] --- result ---"
if [ "$fail" = "0" ]; then
    echo "[term_editor] RESULT: PASS"
    exit 0
else
    echo "[term_editor] RESULT: FAIL"
    exit 1
fi
