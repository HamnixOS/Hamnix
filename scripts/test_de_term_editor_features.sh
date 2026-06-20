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
#   3. Mouse-wheel scrollback.   hamtermscene opens /dev/wsys/<wid>/pointer,
#      parses the wheel-notch (dz) field, and drives a retained scrollback
#      history ring (sb_rows) through a view offset (term_view_off).
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

note "--- (2) command history (Up/Down) ---"
need   "$HAMSH" "hist_append" "history ring append exists"
need   "$HAMSH" "_hist_load"  "history recall loads a stored line"
needre "$HAMSH" "c == 65" "Up arrow (ESC [ A) walks to older history"
needre "$HAMSH" "c == 66" "Down arrow (ESC [ B) walks to newer history"
# The completed line is pushed into history after Enter.
needre "$HAMSH" "hist_append\(&ed_buf\[0\]" "entered line is pushed to history"

note "--- (3) mouse-wheel scrollback ---"
need   "$HTS" "/pointer" "hamtermscene opens the /pointer event stream"
need   "$HTS" "_drain_pointer_chunk" "pointer lines are parsed for the wheel notch"
need   "$HTS" "term_view_off" "a scrollback view offset exists"
need   "$HTS" "sb_rows" "a retained scrollback history ring exists"
need   "$HTS" "_sb_push" "rows scrolled off the top are pushed into history"
needre "$HTS" "_grid_hash" "the view offset is folded into the grid hash (re-commit on scroll)"
# Wheel handling: dz>0 older, dz<0 toward tail, clamped; typing snaps back.
need   "$HTS" "_scroll_by" "wheel notches adjust the scrollback view (clamped)"
needre "$HTS" "term_view_off = 0" "typing snaps the view back to the live tail"

note "--- (4) clean standalone compile of both binaries ---"
ADDER="python3 -m compiler.adder compile --target=x86_64-adder-user"
TMP_HAMSH=$(mktemp --tmpdir te-hamsh.XXXXXX.elf)
TMP_HTS=$(mktemp --tmpdir te-hts.XXXXXX.elf)
cleanup() { rm -f "$TMP_HAMSH" "$TMP_HTS"; }
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

echo "[term_editor] --- result ---"
if [ "$fail" = "0" ]; then
    echo "[term_editor] RESULT: PASS"
    exit 0
else
    echo "[term_editor] RESULT: FAIL"
    exit 1
fi
