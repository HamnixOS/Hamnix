#!/usr/bin/env bash
# scripts/framediff_run.sh — browser fidelity harness (single page).
#
# Renders ONE page three ways on the DEV HOST (no QEMU):
#   (a) hambrowse   — the native engine's host render-to-PNG dual target
#                     (user/hambrowse_host.ad -> scripts/render_hambrowse_png.py)
#   (b) chromium    — headless screenshot, matched viewport width
#   (c) firefox     — headless screenshot (second reference; best-effort)
# then normalizes geometry (scripts/framediff_prep.py) and scores hambrowse
# against each reference with ImageMagick `compare` (RMSE + fuzzed AE), emitting
# a side-by-side montage and a heatmap diff PNG per reference.
#
# The score is a RELATIVE dev metric: lower RMSE == closer to the reference.
# It is NOT pixel-parity — hambrowse packs text on a fixed cell grid, so expect a
# floor from font/hinting/antialias differences (masked with -fuzz). See
# docs/browser_framediff.md for what is a real fidelity gap vs a harness artifact.
#
# USAGE
#   scripts/framediff_run.sh <page.html> [width]
# Outputs (under build/framediff/<name>/):
#   hb.png ref_chromium.png ref_firefox.png
#   diff_chromium.png diff_firefox.png sxs_chromium.png sxs_firefox.png
#   score.txt   (machine-readable: "engine rmse rmse_norm ae")
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
ROOT="$PWD"

PAGE="${1:?usage: framediff_run.sh <page.html> [width]}"
WIDTH="${2:-800}"
[ -f "$PAGE" ] || { echo "[framediff] no such page: $PAGE"; exit 1; }
PAGE_ABS="$(readlink -f "$PAGE")"
NAME="$(basename "$PAGE" .html)"

OUT="build/framediff/$NAME"
mkdir -p "$OUT"
BIN="build/host/hambrowse_host"

# ---- build the host harness once (reuse if present) --------------------------
if [ ! -x "$BIN" ]; then
    echo "[framediff] compiling hambrowse host harness (x86_64-linux) ..."
    mkdir -p build/host
    if ! python3 -m compiler.adder compile --target=x86_64-linux \
            user/hambrowse_host.ad -o "$BIN" 2>"build/host/framediff_compile.log"; then
        echo "[framediff] FAIL: host harness did not compile"
        cat build/host/framediff_compile.log; exit 1
    fi
fi

# ---- (a) hambrowse host render-to-PNG ----------------------------------------
DUMP="$OUT/dump.txt"
if ! "$BIN" "$PAGE_ABS" "$WIDTH" >"$DUMP" 2>&1; then
    echo "[framediff] FAIL: hambrowse host render exited non-zero"; cat "$DUMP"; exit 1
fi
python3 scripts/render_hambrowse_png.py "$OUT/hb_full.png" \
    --dump "$DUMP" --url "file://$NAME.html" --title "$NAME" >/dev/null

# ---- (b) chromium headless ---------------------------------------------------
# Full-page height: give a tall viewport and let framediff_prep trim the tail.
VH=$((WIDTH * 3))
have_ref=""
CHROME_OK=""
if command -v chromium >/dev/null 2>&1; then
    rm -f "$OUT/chromium_raw.png"
    chromium --headless --no-sandbox --disable-gpu --hide-scrollbars \
        --force-device-scale-factor=1 --default-background-color=FFFFFFFF \
        --screenshot="$ROOT/$OUT/chromium_raw.png" \
        --window-size="$WIDTH,$VH" "file://$PAGE_ABS" \
        >"$OUT/chromium.log" 2>&1
    [ -s "$OUT/chromium_raw.png" ] && CHROME_OK=1
fi

# ---- (c) firefox headless (best-effort) --------------------------------------
FF_OK=""
if command -v firefox >/dev/null 2>&1; then
    rm -f "$OUT/firefox_raw.png"
    # firefox requires an ABSOLUTE screenshot path
    firefox --headless --window-size="$WIDTH,$VH" \
        --screenshot "$ROOT/$OUT/firefox_raw.png" "file://$PAGE_ABS" \
        >"$OUT/firefox.log" 2>&1
    [ -s "$OUT/firefox_raw.png" ] && FF_OK=1
fi

: >"$OUT/score.txt"

# score hambrowse against one reference engine; args: <engine> <raw.png>
score_against() {
    local engine="$1" raw="$2"
    local ohb="$OUT/hb.png" oref="$OUT/ref_$engine.png"
    python3 scripts/framediff_prep.py "$OUT/hb_full.png" "$raw" "$ohb" "$oref" \
        >"$OUT/prep_$engine.log" 2>&1 || {
        echo "[framediff] prep failed for $engine"; cat "$OUT/prep_$engine.log"; return 1; }

    # RMSE (0..1 normalized in parens) and fuzzed absolute pixel-error count.
    local rmse ae rmse_norm
    rmse="$(compare -metric RMSE "$ohb" "$oref" "$OUT/diff_$engine.png" 2>&1)"
    ae="$(compare -metric AE -fuzz 8% "$ohb" "$oref" null: 2>&1)"
    # rmse looks like: "1234.5 (0.018837)"
    rmse_norm="$(printf '%s' "$rmse" | sed -E 's/.*\(([0-9.]+)\).*/\1/')"
    rmse="$(printf '%s' "$rmse" | awk '{print $1}')"

    # Structural metric (SSIM + blurred RMSE). NB this is a MONO-GRID preview: the
    # text-dump path lays text on the 8px char grid (no proportional reflow), so
    # even the structural score is only a rough preview — the parity signal is the
    # pixel harness (scripts/framediff_gfx_run.sh). See scripts/framediff_metric.py.
    local m ssim brmse
    m="$(python3 scripts/framediff_metric.py "$ohb" "$oref" 2>>"$OUT/prep_$engine.log")"
    ssim="$(printf '%s' "$m"  | sed -E 's/.* ssim=([0-9.]+).*/\1/')"
    brmse="$(printf '%s' "$m" | sed -E 's/.*brmse=([0-9.]+).*/\1/')"
    [ -n "$ssim" ] || ssim="n/a"; [ -n "$brmse" ] || brmse="n/a"

    # side-by-side: hambrowse | reference | heatmap
    montage -label 'hambrowse' "$ohb" -label "$engine" "$oref" \
        -label 'diff' "$OUT/diff_$engine.png" \
        -tile 3x1 -geometry +4+4 -background '#dddddd' \
        "$OUT/sxs_$engine.png" >/dev/null 2>&1

    # score.txt line: engine rmse rmse_norm ae ssim brmse
    printf '%s %s %s %s %s %s\n' "$engine" "$rmse" "$rmse_norm" "$ae" \
        "$ssim" "$brmse" >>"$OUT/score.txt"
    printf '[framediff] %-8s vs %-8s  SSIM=%-9s brmse=%-9s RMSE=%-10s (norm %-9s)\n' \
        "$NAME" "$engine" "$ssim" "$brmse" "$rmse" "$rmse_norm"
}

[ -n "$CHROME_OK" ] && { score_against chromium "$OUT/chromium_raw.png" && have_ref=1; } \
    || echo "[framediff] chromium reference unavailable (see $OUT/chromium.log)"
[ -n "$FF_OK" ] && score_against firefox "$OUT/firefox_raw.png" \
    || echo "[framediff] firefox reference unavailable (see $OUT/firefox.log)"

[ -n "$have_ref" ] || { echo "[framediff] RESULT: no references produced for $NAME"; exit 1; }
echo "[framediff] wrote $OUT/ (hb.png, ref_*.png, diff_*.png, sxs_*.png, score.txt)"
