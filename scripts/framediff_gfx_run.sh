#!/usr/bin/env bash
# scripts/framediff_gfx_run.sh — PIXEL browser-fidelity harness (single page).
#
# This is the successor to scripts/framediff_run.sh. The old harness diffed
# hambrowse's TEXT-MODE host dump, which misrepresents proportional text
# (project memory: feedback_host_preview_monospace_lies). THIS harness diffs the
# REAL pixel renderer — the `hambrowse_host_gfx` backend (lib/htmlpage +
# lib/htmlpaint), the SAME layout+paint code that runs on device — against the
# two engines the USER wants hambrowse to "render like": chromium AND firefox.
#
# It renders ONE page three ways on the DEV HOST (no QEMU):
#   (a) hambrowse — user/hambrowse_host_gfx.ad -> PPM -> PNG (pixel canvas)
#   (b) chromium  — headless --screenshot, matched viewport, white bg
#   (c) firefox   — headless --screenshot, matched viewport, white bg
# The three are driven with the SAME DejaVu faces at the SAME default UA sizes
# so the metric tracks LAYOUT + PAINT, not a font mismatch. Geometry is
# normalized (scripts/framediff_gfx_prep.py: flatten-white, content-bbox trim,
# resize reference to the hambrowse content box) and scored with ImageMagick
# `compare` (RMSE + a fuzzed absolute-error count that tolerates anti-alias
# noise). A side-by-side montage and a heatmap diff PNG are emitted per engine.
#
# Lower RMSE == closer to the reference. chromium and firefox should broadly
# AGREE per page (cross-validation); a page where they diverge means the
# reference itself is ambiguous, not that hambrowse is uniquely wrong.
#
# USAGE
#   scripts/framediff_gfx_run.sh <page.html> [width]
# Outputs (under build/framediff_gfx/<name>/):
#   hb.png ref_chromium.png ref_firefox.png
#   diff_chromium.png diff_firefox.png sxs_chromium.png sxs_firefox.png
#   score.txt   (machine-readable per line: "engine rmse rmse_norm ae")
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
ROOT="$PWD"

PAGE="${1:?usage: framediff_gfx_run.sh <page.html> [width]}"
WIDTH="${2:-800}"
[ -f "$PAGE" ] || { echo "[framediff-gfx] no such page: $PAGE"; exit 1; }
PAGE_ABS="$(readlink -f "$PAGE")"
NAME="$(basename "$PAGE" .html)"
FUZZ="${FRAMEDIFF_FUZZ:-6%}"     # AA / hinting tolerance for the fuzzed AE count

OUT="build/framediff_gfx/$NAME"
mkdir -p "$OUT"
BIN="build/host/hambrowse_gfx"

# ---- build the pixel backend once (reuse if present) -------------------------
if [ ! -x "$BIN" ]; then
    echo "[framediff-gfx] compiling pixel backend (x86_64-linux) ..."
    mkdir -p build/host
    if ! python3 -m compiler.adder compile --target=x86_64-linux \
            user/hambrowse_host_gfx.ad -o "$BIN" 2>"build/host/framediff_gfx_compile.log"; then
        echo "[framediff-gfx] FAIL: pixel backend did not compile"
        cat build/host/framediff_gfx_compile.log; exit 1
    fi
fi

# ---- (a) hambrowse pixel render ----------------------------------------------
PPM="$OUT/hb.ppm"
DUMP="$OUT/dump.txt"
if ! "$BIN" "$PAGE_ABS" "$PPM" "$WIDTH" >"$DUMP" 2>&1; then
    echo "[framediff-gfx] FAIL: hambrowse pixel render exited non-zero"; cat "$DUMP"; exit 1
fi
if ! python3 scripts/ppm_to_png.py "$PPM" "$OUT/hb_full.png" >"$OUT/png.log" 2>&1; then
    echo "[framediff-gfx] FAIL: PPM->PNG conversion"; cat "$OUT/png.log"; exit 1
fi
# the hambrowse canvas width (references are shot at this width to minimise the
# horizontal resize the normalizer has to apply).
read HBW HBH < <(python3 - "$OUT/hb_full.png" <<'PY'
from PIL import Image; import sys
w, h = Image.open(sys.argv[1]).size; print(w, h)
PY
)
VW="$HBW"
VH=$((HBH + 40))          # a little slack so nothing is clipped at the bottom

# ---- (b) chromium headless ---------------------------------------------------
CHROME_OK=""
if command -v chromium >/dev/null 2>&1; then
    rm -f "$OUT/chromium_raw.png"
    chromium --headless --no-sandbox --disable-gpu --hide-scrollbars \
        --force-device-scale-factor=1 --default-background-color=FFFFFFFF \
        --screenshot="$ROOT/$OUT/chromium_raw.png" \
        --window-size="$VW,$VH" "file://$PAGE_ABS" \
        >"$OUT/chromium.log" 2>&1
    [ -s "$OUT/chromium_raw.png" ] && CHROME_OK=1
fi

# ---- (c) firefox headless ----------------------------------------------------
FF_OK=""
if command -v firefox >/dev/null 2>&1; then
    rm -f "$OUT/firefox_raw.png"
    firefox --headless --window-size="$VW,$VH" \
        --screenshot "$ROOT/$OUT/firefox_raw.png" "file://$PAGE_ABS" \
        >"$OUT/firefox.log" 2>&1
    [ -s "$OUT/firefox_raw.png" ] && FF_OK=1
fi

: >"$OUT/score.txt"
have_ref=""

# score hambrowse against one reference engine; args: <engine> <raw.png>
score_against() {
    local engine="$1" raw="$2"
    local ohb="$OUT/hb.png" oref="$OUT/ref_$engine.png"
    python3 scripts/framediff_gfx_prep.py "$OUT/hb_full.png" "$raw" "$ohb" "$oref" \
        >"$OUT/prep_$engine.log" 2>&1 || {
        echo "[framediff-gfx] prep failed for $engine"; cat "$OUT/prep_$engine.log"; return 1; }

    local rmse ae rmse_norm
    rmse="$(compare -metric RMSE "$ohb" "$oref" "$OUT/diff_$engine.png" 2>&1)"
    ae="$(compare -metric AE -fuzz "$FUZZ" "$ohb" "$oref" null: 2>&1)"
    rmse_norm="$(printf '%s' "$rmse" | sed -E 's/.*\(([0-9.]+)\).*/\1/')"
    rmse="$(printf '%s' "$rmse" | awk '{print $1}')"

    montage -label 'hambrowse (pixel)' "$ohb" -label "$engine" "$oref" \
        -label "diff (fuzz $FUZZ)" "$OUT/diff_$engine.png" \
        -tile 3x1 -geometry +4+4 -background '#dddddd' \
        "$OUT/sxs_$engine.png" >/dev/null 2>&1

    printf '%s %s %s %s\n' "$engine" "$rmse" "$rmse_norm" "$ae" >>"$OUT/score.txt"
    printf '[framediff-gfx] %-10s vs %-8s  RMSE=%-10s (norm %-9s)  AE(fuzz %s)=%s\n' \
        "$NAME" "$engine" "$rmse" "$rmse_norm" "$FUZZ" "$ae"
    return 0
}

[ -n "$CHROME_OK" ] && { score_against chromium "$OUT/chromium_raw.png" && have_ref=1; } \
    || echo "[framediff-gfx] chromium reference unavailable (see $OUT/chromium.log)"
[ -n "$FF_OK" ] && { score_against firefox "$OUT/firefox_raw.png" && have_ref=1; } \
    || echo "[framediff-gfx] firefox reference unavailable (see $OUT/firefox.log)"

[ -n "$have_ref" ] || { echo "[framediff-gfx] RESULT: no references produced for $NAME"; exit 1; }
echo "[framediff-gfx] wrote $OUT/ (hb.png, ref_*.png, diff_*.png, sxs_*.png, score.txt)"
