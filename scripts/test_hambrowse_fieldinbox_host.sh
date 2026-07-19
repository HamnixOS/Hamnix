#!/usr/bin/env bash
# scripts/test_hambrowse_fieldinbox_host.sh — FAST, QEMU-free render-to-PNG gate
# proving that TEXT typed into a form control lands INSIDE the control's drawn
# box, and that <textarea> + <input type=submit> paint as REAL bordered boxes
# (not the bracket/underscore ASCII fallback).
#
# WHY THIS GATE EXISTS
#   On-device the user saw hambrowse "mangled": google's search field and its
#   Search / I'm-Feeling-Lucky buttons rendered as bare '[cats____]' / '[ label ]'
#   glyphs with NO box, and "text typed into a text box renders slightly OUTSIDE
#   the text box." Root cause: the <textarea> branch and the <input type=submit>
#   branch in lib/web/dom/forms.ad never committed a seg_field/seg_button segment,
#   so the pixel renderer drew raw ASCII instead of a bordered field/button box.
#   The TEXT-MODE host harness (test_hambrowse_host.sh) CANNOT catch this — the
#   bracket glyphs are present in the text dump either way. Only a PIXEL scan of
#   the real TTF-painted framebuffer proves the box + text geometry, so this gate
#   scans the PPM the shipped painter (lib/htmlpage.ad, shared host+device) emits.
#
# ASSERTIONS
#   1. SEGCTRL geometry: the <textarea> and the text <input> commit as kind-1
#      fields; the <input type=submit> commits as a kind-2 button. (Before the
#      fix there were ZERO SEGCTRL lines for these — they were plain text.)
#   2. Pixel invariant (the part a text harness can't see): in the field's row
#      band a real light-fill (0xf1f3f4) box is painted, and the rightmost DARK
#      (text/caret) pixel sits INSIDE that box — no glyph ink spills past the box
#      right edge. Same for the button's grey (0xe0e3e7) face.
#
# Builds the pixel backend (x86_64-linux) AND native hambrowse (x86_64-adder-user)
# so a regression in either target fails here. NO QEMU.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/hambrowse_gfx_fib"
FIX="tests/fixtures/hambrowse_fieldinbox.html"
PPM="$OUT/fieldinbox.ppm"
PNG="$OUT/fieldinbox.png"
mkdir -p "$OUT"
fail=0

echo "[hb-fib] compiling pixel backend for x86_64-linux ..."
if ! python3 -m compiler.adder compile --target=x86_64-linux \
        user/hambrowse_host_gfx.ad -o "$BIN" 2>"$OUT/fib_compile.log"; then
    echo "[hb-fib] FAIL: pixel backend did not compile"; cat "$OUT/fib_compile.log"; exit 1
fi
echo "[hb-fib] PASS pixel backend compiled"

echo "[hb-fib] confirming NATIVE hambrowse still compiles ..."
if ! python3 -m compiler.adder compile --target=x86_64-adder-user \
        user/hambrowse.ad -o "$OUT/fib_native.elf" 2>"$OUT/fib_native.log"; then
    echo "[hb-fib] FAIL: native hambrowse did not compile"; cat "$OUT/fib_native.log"; exit 1
fi
echo "[hb-fib] PASS native hambrowse still compiles"

D="$OUT/fib_dump.txt"
if ! "$BIN" "$FIX" "$PPM" 480 >"$D" 2>&1; then
    echo "[hb-fib] FAIL: render exited non-zero"; cat "$D"; exit 1
fi
python3 scripts/ppm_to_png.py "$PPM" "$PNG" >/dev/null 2>&1 && echo "[hb-fib] wrote $PNG"

# (1) SEGCTRL geometry — kinds in fixture order: textarea(1), text input(1),
# submit(2). A control rendered as bracket ASCII emits NO SEGCTRL line.
kinds=$(grep -E "^SEGCTRL " "$D" | awk '{print $2}' | tr '\n' ' ')
echo "[hb-fib] SEGCTRL kinds: ${kinds:-<none>}"
if [ "$(printf '%s' "$kinds")" = "1 1 2 " ]; then
    echo "[hb-fib] PASS textarea+input=field(1), submit=button(2)"
else
    echo "[hb-fib] FAIL SEGCTRL kinds '${kinds}' want '1 1 2 ' (controls not committed as real boxes)"; fail=1
fi

# (2) Pixel invariant: the text/caret ink stays INSIDE the painted box for both
# the field (light fill 0xf1f3f4) and the button (grey face 0xe0e3e7).
probe=$(python3 - "$PPM" <<'PY'
import sys
f=open(sys.argv[1],'rb')
if f.readline().strip()!=b'P6': print("BADPPM"); sys.exit(0)
w,h=map(int,f.readline().split()); f.readline(); d=f.read()
def px(x,y): return d[(y*w+x)*3:(y*w+x)*3+3]
def isdark(p): return p[0]<110 and p[1]<110 and p[2]<110
def band(col):
    col=bytes(col)
    rows=[y for y in range(h) if sum(1 for x in range(w) if px(x,y)==col)>=15]
    if not rows: return None
    y0,y1=min(rows),max(rows)
    fillmaxx=max(x for y in rows for x in range(w) if px(x,y)==col)
    darkxs=[x for y in range(y0,y1+1) for x in range(w) if isdark(px(x,y))]
    darkmaxx=max(darkxs) if darkxs else -1
    return (fillmaxx,darkmaxx)
fld=band((241,243,244)); btn=band((224,227,231))
if not fld: print("NOFIELD"); sys.exit(0)
if not btn: print("NOBUTTON"); sys.exit(0)
# overflow = how far the rightmost text pixel spills past the box right edge.
print(f"FIELD {fld[0]} {fld[1]} {fld[1]-fld[0]} BUTTON {btn[0]} {btn[1]} {btn[1]-btn[0]}")
PY
)
echo "[hb-fib] pixel probe: $probe"
case "$probe" in
  NOFIELD*)  echo "[hb-fib] FAIL: no light-fill field box painted (fell back to ASCII?)"; fail=1;;
  NOBUTTON*) echo "[hb-fib] FAIL: no grey-face button box painted (fell back to ASCII?)"; fail=1;;
  BADPPM*)   echo "[hb-fib] FAIL: unreadable PPM"; fail=1;;
  FIELD*)
    fld_over=$(printf '%s' "$probe" | awk '{print $4}')
    btn_over=$(printf '%s' "$probe" | awk '{print $8}')
    fld_dark=$(printf '%s' "$probe" | awk '{print $3}')
    btn_dark=$(printf '%s' "$probe" | awk '{print $7}')
    # <=2px tolerance covers the box's own 1-2px border stroke on the fill edge.
    if [ "$fld_dark" -ge 0 ] && [ "$fld_over" -le 2 ]; then
        echo "[hb-fib] PASS field text inside box (rightmost ink ${fld_over}px vs box edge)"
    else
        echo "[hb-fib] FAIL field text spills ${fld_over}px past box edge (text OUTSIDE the box)"; fail=1
    fi
    if [ "$btn_dark" -ge 0 ] && [ "$btn_over" -le 2 ]; then
        echo "[hb-fib] PASS button label inside box (rightmost ink ${btn_over}px vs box edge)"
    else
        echo "[hb-fib] FAIL button label spills ${btn_over}px past box edge"; fail=1
    fi;;
  *) echo "[hb-fib] FAIL: unexpected probe output"; fail=1;;
esac

if [ "$fail" -ne 0 ]; then echo "[hb-fib] RESULT: FAIL"; exit 1; fi
echo "[hb-fib] RESULT: PASS — textarea/input/submit paint real boxes with text inside"
