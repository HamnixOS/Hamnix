#!/usr/bin/env bash
# scripts/test_hambrowse_history.sh — FAST, QEMU-free gate for the browser's
# BACK / FORWARD navigation history (lib/browserhistory.ad) and the Back/Forward
# chrome buttons (lib/browserwin.ad).
#
# Two rungs, both on the host:
#   (1) MODEL — user/browserhist_host.ad drives the pure session-history model
#       directly and we assert the classic browser semantics: push discards the
#       forward stack, back()/forward() walk the cursor WITHOUT pushing, a reload
#       of the current URL is a no-op, and can_back/can_fwd gate the buttons.
#   (2) CHROME — user/hambrowse_gfx_window.ad composites the real window via the
#       SHARED compositor lib/browserwin.ad with the Back/Forward state toggled,
#       and we sample the button pixels: an ENABLED button is chrome-blue, a
#       DISABLED one is greyed. This is the exact code the native browser paints.
#
# Also confirms the NATIVE hambrowse (which wires both) still compiles for
# x86_64-adder-user. Built with the frozen Python seed compiler.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
mkdir -p "$OUT"
fail=0

# --------------------------------------------------------------------
# NATIVE regression: the on-device browser wiring must still compile.
# --------------------------------------------------------------------
echo "[hb-hist] compiling native hambrowse for x86_64-adder-user ..."
if ! python3 -m compiler.adder compile --target=x86_64-adder-user \
        user/hambrowse.ad -o "$OUT/hambrowse_native.elf" 2>"$OUT/hist_native.log"; then
    echo "[hb-hist] FAIL: native hambrowse did not compile"; cat "$OUT/hist_native.log"; exit 1
fi
echo "[hb-hist] PASS native hambrowse still compiles (back/forward wired)"

# --------------------------------------------------------------------
# (1) MODEL rung.
# --------------------------------------------------------------------
MBIN="$OUT/browserhist_host"
echo "[hb-hist] compiling history-model harness for x86_64-linux ..."
if ! python3 -m compiler.adder compile --target=x86_64-linux \
        user/browserhist_host.ad -o "$MBIN" 2>"$OUT/hist_model.log"; then
    echo "[hb-hist] FAIL: model harness did not compile"; cat "$OUT/hist_model.log"; exit 1
fi
MDUMP="$OUT/hist_model.txt"
if ! "$MBIN" >"$MDUMP" 2>&1; then
    echo "[hb-hist] FAIL: model harness exited non-zero"; cat "$MDUMP"; exit 1
fi
cat "$MDUMP"

assert_m() {
    local pat="$1" msg="$2"
    if grep -Pzoq -- "$pat" "$MDUMP"; then
        echo "[hb-hist] PASS $msg"
    else
        echo "[hb-hist] FAIL $msg (missing: $pat)"; fail=1
    fi
}

assert_m '(?m)^STATE empty cur=- idx=-1 count=0 back=0 fwd=0$' \
    "empty history: no current entry, Back+Forward both disabled"
assert_m '(?m)^STATE visited_abc cur=http://c/ idx=2 count=3 back=1 fwd=0$' \
    "visiting A,B,C lands at C with Back enabled, Forward disabled"
assert_m '(?m)^STATE reload_c cur=http://c/ idx=2 count=3 back=1 fwd=0$' \
    "reloading the current URL is a no-op (count stays 3)"
# Back C->B->A, then a refused back.
assert_m '(?m)^BACK ok=1\nSTATE after_back cur=http://b/ idx=1 count=3 back=1 fwd=1$' \
    "Back from C re-navigates to B (Forward now enabled)"
assert_m '(?m)^BACK ok=1\nSTATE after_back cur=http://a/ idx=0 count=3 back=0 fwd=1$' \
    "Back from B re-navigates to A (Back now disabled at the oldest entry)"
assert_m '(?m)^BACK ok=0\nSTATE after_back cur=http://a/ idx=0 count=3 back=0 fwd=1$' \
    "Back at the oldest entry is refused (no URL, state unchanged)"
# Forward A->B.
assert_m '(?m)^FWD ok=1\nSTATE after_fwd cur=http://b/ idx=1 count=3 back=1 fwd=1$' \
    "Forward from A re-navigates to B"
# Branch: from B visit D -> forward history (C) discarded.
assert_m '(?m)^STATE branch_d cur=http://d/ idx=2 count=3 back=1 fwd=0$' \
    "visiting D from B discards the forward entry C (Forward disabled)"
assert_m '(?m)^FWD ok=0\nSTATE after_fwd cur=http://d/ idx=2 count=3 back=1 fwd=0$' \
    "Forward at the tip after branching is refused (C is gone)"

# --------------------------------------------------------------------
# (2) CHROME rung — render the window with the Back/Forward state toggled and
# sample the button pixels (enabled=chrome-blue 58,110,165; disabled=grey).
# --------------------------------------------------------------------
WBIN="$OUT/hambrowse_gfx_window"
echo "[hb-hist] compiling window compositor for x86_64-linux ..."
if ! python3 -m compiler.adder compile --target=x86_64-linux \
        user/hambrowse_gfx_window.ad -o "$WBIN" 2>"$OUT/hist_win.log"; then
    echo "[hb-hist] FAIL: window compositor did not compile"; cat "$OUT/hist_win.log"; exit 1
fi

FIX="tests/fixtures/hambrowse_img.html"
# Back button spans x=4..24, Forward x=26..46, both on the address band (y~26).
# Sample the button centres from the PPM (P6, 880x600).
sample_px() {   # PPM x y -> "R G B"
    python3 - "$1" "$2" "$3" <<'PY'
import sys
p=open(sys.argv[1],'rb'); assert p.readline().strip()==b'P6'
w,h=map(int,p.readline().split()); p.readline()
data=p.read(); x=int(sys.argv[2]); y=int(sys.argv[3]); o=(y*w+x)*3
print(data[o],data[o+1],data[o+2])
PY
}

render_state() {  # name can_back can_fwd
    local name="$1" cb="$2" cf="$3"
    local ppm="$OUT/hist_$name.ppm" png="$OUT/hist_$name.png"
    if ! "$WBIN" "$FIX" "$ppm" 880 600 "$cb" "$cf" >"$OUT/hist_${name}.txt" 2>&1; then
        echo "[hb-hist] FAIL: window render ($name) exited non-zero"; cat "$OUT/hist_${name}.txt"; fail=1; return
    fi
    python3 scripts/ppm_to_png.py "$ppm" "$png" 2>/dev/null && \
        echo "[hb-hist] rendered $png (back=$cb fwd=$cf)"
    B_BACK=$(sample_px "$ppm" 6 26)
    B_FWD=$(sample_px "$ppm" 28 26)
    echo "[hb-hist]   back-btn px=$B_BACK  fwd-btn px=$B_FWD"
}

# Chrome-blue when enabled: R<120 and B>130. Greyed when disabled: R>180.
is_blue() { local r g b; read r g b <<<"$1"; [ "$r" -lt 120 ] && [ "$b" -gt 130 ]; }
is_grey() { local r g b; read r g b <<<"$1"; [ "$r" -gt 180 ]; }

render_state "chrome_disabled" 0 0
is_grey "$B_BACK" && echo "[hb-hist] PASS disabled Back button is greyed" || { echo "[hb-hist] FAIL disabled Back not greyed ($B_BACK)"; fail=1; }
is_grey "$B_FWD"  && echo "[hb-hist] PASS disabled Forward button is greyed" || { echo "[hb-hist] FAIL disabled Forward not greyed ($B_FWD)"; fail=1; }

render_state "chrome_back" 1 0
is_blue "$B_BACK" && echo "[hb-hist] PASS enabled Back button is chrome-blue" || { echo "[hb-hist] FAIL enabled Back not blue ($B_BACK)"; fail=1; }
is_grey "$B_FWD"  && echo "[hb-hist] PASS Forward stays greyed when only Back is available" || { echo "[hb-hist] FAIL Forward not greyed ($B_FWD)"; fail=1; }

render_state "chrome_both" 1 1
is_blue "$B_BACK" && echo "[hb-hist] PASS Back button blue when both available" || { echo "[hb-hist] FAIL Back not blue ($B_BACK)"; fail=1; }
is_blue "$B_FWD"  && echo "[hb-hist] PASS Forward button blue when both available" || { echo "[hb-hist] FAIL Forward not blue ($B_FWD)"; fail=1; }

if [ "$fail" -eq 0 ]; then
    echo "[hb-hist] RESULT: PASS"
else
    echo "[hb-hist] RESULT: FAIL"
fi
exit "$fail"
