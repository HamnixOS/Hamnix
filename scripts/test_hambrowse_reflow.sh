#!/usr/bin/env bash
# scripts/test_hambrowse_reflow.sh — FAST, QEMU-free gate for TRUE LINE REFLOW
# at the pixel measure: the engine's line-breaker (lib/htmlengine.ad) now
# measures candidate lines in REAL proportional TrueType advances (via the
# htmlpage_install_reflow() width hook into lib/htmlpage.ad) and breaks at the
# last word boundary that fits the window, instead of counting 8px char cells.
#
# Before this, the layout wrapped on an 8px monospace grid while the renderer
# flowed wider TrueType advances, so long lines overran the viewport and the
# page canvas grew SIDEWAYS. This gate proves prose now WRAPS to the window:
#   * every flowed prose segment is painted within the viewport width pw
#     (REFLOW overflow == 0, maxx <= pw)   -> no glyph clipping, no side-growth;
#   * a long paragraph occupies MANY visual rows                -> it wrapped;
#   * the whole canvas width stays within pw + a small pad      -> not sideways.
# It also confirms a control render WITHOUT the reflow hook overruns (maxx > pw),
# so the assertion is proving the fix, not a tautology, and that the NATIVE
# hambrowse still compiles from the same shared engine.
#
# Built with the frozen Python seed compiler. PNG conversion is stdlib-only.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/hambrowse_gfx"
mkdir -p "$OUT"
fail=0

echo "[hb-reflow] compiling pixel backend for x86_64-linux ..."
if ! python3 -m compiler.adder compile --target=x86_64-linux \
        user/hambrowse_host_gfx.ad -o "$BIN" 2>"$OUT/reflow_compile.log"; then
    echo "[hb-reflow] FAIL: driver did not compile"; cat "$OUT/reflow_compile.log"; exit 1
fi
echo "[hb-reflow] PASS pixel backend compiled"

echo "[hb-reflow] confirming NATIVE hambrowse still compiles ..."
if ! python3 -m compiler.adder compile --target=x86_64-adder-user \
        user/hambrowse.ad -o "$OUT/hambrowse_native.elf" 2>"$OUT/reflow_native.log"; then
    echo "[hb-reflow] FAIL: native hambrowse did not compile"; cat "$OUT/reflow_native.log"; exit 1
fi
echo "[hb-reflow] PASS native hambrowse still compiles"

FIX="tests/fixtures/hambrowse_reflow.html"
W=500
DUMP="$OUT/reflow_dump.txt"
PPM="$OUT/reflow_after.ppm"
PNG="$OUT/reflow_after.png"

echo "[hb-reflow] rendering $FIX at width $W (reflow ON) ..."
if ! "$BIN" "$FIX" "$PPM" "$W" >"$DUMP" 2>&1; then
    echo "[hb-reflow] FAIL: render exited non-zero"; cat "$DUMP"; exit 1
fi
grep -E '^CANVAS|^REFLOW' "$DUMP"
python3 scripts/ppm_to_png.py "$PPM" "$PNG" >/dev/null 2>&1 \
    && echo "[hb-reflow] wrote $PNG ($(file -b "$PNG" 2>/dev/null))"

# Parse the REFLOW line: "REFLOW pw <pw> maxx <maxx> overflow <n> textrows <n>"
read PW MAXX OVER TROWS < <(awk '/^REFLOW / {print $3, $5, $7, $9; exit}' "$DUMP")
CANVW=$(awk '/^CANVAS / {print $2; exit}' "$DUMP")
echo "[hb-reflow] pw=$PW maxx=$MAXX overflow=$OVER textrows=$TROWS canvas_w=$CANVW"

# (1) No prose segment overruns the viewport -> nothing clips / no side-growth.
if [ "${OVER:-1}" -eq 0 ]; then
    echo "[hb-reflow] PASS no prose overruns the viewport (overflow=0)"
else
    echo "[hb-reflow] FAIL $OVER prose segment(s) painted past pw=$PW"; fail=1
fi

# (2) Rightmost painted prose x is within the window width.
if [ -n "${MAXX:-}" ] && [ -n "${PW:-}" ] && [ "$MAXX" -le "$PW" ]; then
    echo "[hb-reflow] PASS max painted prose x ($MAXX) <= window pw ($PW)"
else
    echo "[hb-reflow] FAIL max painted prose x ($MAXX) exceeds pw ($PW)"; fail=1
fi

# (3) The long paragraphs wrapped onto MANY rows (a single unwrapped line would
# be ~2). At 500px this fixture is ~15+ text rows.
if [ -n "${TROWS:-}" ] && [ "$TROWS" -ge 8 ]; then
    echo "[hb-reflow] PASS long paragraph wrapped to many rows (textrows=$TROWS)"
else
    echo "[hb-reflow] FAIL paragraph did not wrap to multiple rows (textrows=$TROWS)"; fail=1
fi

# (4) The canvas width is the WINDOW width (+ small right pad), NOT grown to the
# longest unwrapped line.
if [ -n "${CANVW:-}" ] && [ "$CANVW" -le "$((W + 16))" ]; then
    echo "[hb-reflow] PASS canvas width ($CANVW) is the window ($W), not grown sideways"
else
    echo "[hb-reflow] FAIL canvas grew sideways ($CANVW > $((W + 16)))"; fail=1
fi

# (5) CONTROL: the SAME fixture WITHOUT the reflow hook must overrun, proving the
# gate measures the fix and is not vacuously true. Build a hook-less driver copy.
BEFORE_SRC="$OUT/_reflow_before_driver.ad"
BEFORE_BIN="$OUT/hambrowse_gfx_noreflow"
sed 's/^\( *\)htmlpage_install_reflow()$/\1pass/' \
    user/hambrowse_host_gfx.ad > "$BEFORE_SRC"
if python3 -m compiler.adder compile --target=x86_64-linux \
        "$BEFORE_SRC" -o "$BEFORE_BIN" 2>"$OUT/reflow_before_compile.log"; then
    "$BEFORE_BIN" "$FIX" "$OUT/reflow_before.ppm" "$W" >"$OUT/reflow_before_dump.txt" 2>&1
    python3 scripts/ppm_to_png.py "$OUT/reflow_before.ppm" "$OUT/reflow_before.png" >/dev/null 2>&1
    read BPW BMAXX BOVER BTROWS < <(awk '/^REFLOW / {print $3, $5, $7, $9; exit}' "$OUT/reflow_before_dump.txt")
    echo "[hb-reflow] control (no reflow): maxx=$BMAXX overflow=$BOVER textrows=$BTROWS (pw=$BPW)"
    # NON-VACUITY: the measure hook must CHANGE line breaking, else the reflow-ON
    # assertions are tautological. Without the hook the breaker wraps on the fixed
    # 8px CELL_W grid, which mis-measures the proportional TTF paint and so wraps
    # to a DIFFERENT result than the true-measure reflow-ON render — either the
    # grid over-packs and a line OVERRUNS the viewport (BOVER>0 / BMAXX>pw), or it
    # over-estimates width and OVER-WRAPS to more rows than reflow-ON (BTROWS>TROWS).
    # (Historically this only checked BMAXX>pw, which assumed the DejaVu advance was
    # WIDER than the 8px grid; once the sans advance was corrected to Chrome's
    # narrower Liberation metric the grid became the WIDER estimate, so the control
    # now over-wraps rather than overruns — both prove the hook is load-bearing.)
    ctrl_differs=0
    if [ -n "${BMAXX:-}" ] && [ "$BMAXX" -gt "$BPW" ]; then ctrl_differs=1; fi
    if [ -n "${BOVER:-}" ] && [ "$BOVER" -gt "${OVER:-0}" ]; then ctrl_differs=1; fi
    if [ -n "${BTROWS:-}" ] && [ -n "${TROWS:-}" ] && [ "$BTROWS" -ne "$TROWS" ]; then ctrl_differs=1; fi
    if [ "$ctrl_differs" -eq 1 ]; then
        echo "[hb-reflow] PASS control (grid wrap) differs from reflow-ON (rows $BTROWS vs $TROWS, maxx $BMAXX vs $MAXX, overflow $BOVER vs $OVER) — hook is load-bearing"
    else
        echo "[hb-reflow] FAIL control matches reflow-ON; gate may be tautological"; fail=1
    fi
else
    echo "[hb-reflow] FAIL control driver did not compile"; cat "$OUT/reflow_before_compile.log"; fail=1
fi

if [ "$fail" -eq 0 ]; then
    echo "[hb-reflow] PASS"
else
    echo "[hb-reflow] FAIL"; exit 1
fi
