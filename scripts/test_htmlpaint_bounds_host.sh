#!/usr/bin/env bash
# scripts/test_htmlpaint_bounds_host.sh — QEMU-free guard on the browser's
# largest BSS working-set buffers.
#
# The native browser (user/hambrowse.ad) is the largest working set of any DE
# app. On a low-RAM (~256 MB) image its pre-window fault-in must stay small
# enough for the window to OPEN — the regression being fixed here was "the web
# browser doesn't open at all" (an OOM during the pre-window render). Two fixed
# BSS buffers dominate that footprint:
#   * lib/htmlpaint.ad  hp_fb        — the RGB paint framebuffer;
#   * lib/png.ad        png_raw/png_out/idat_buf — the PNG decode scratch.
#
# This gate asserts those arrays stay <= a sane cap AND that hp_fb stays exactly
# HP_MAX_W*HP_MAX_H*3, so a future edit cannot silently re-inflate the working
# set (e.g. bumping HP_MAX_H back to 4000 for a 12 MB fb) without turning this
# gate red. It is pure text/arithmetic — no compile, no QEMU.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

fail=0
pass() { echo "[hp-bounds] PASS $1"; }
bad()  { echo "[hp-bounds] FAIL $1"; fail=1; }

# --- extract a `name: <type> = <int>` or `name: Array[<int>, ...]` literal ----
const_of() {  # file  ident   -> integer literal on its definition line
    grep -oE "^${2}:[^=]*=[[:space:]]*[0-9]+" "$1" | grep -oE '[0-9]+$' | head -1
}
arr_of() {    # file  ident   -> Array[<N>, ...] element count
    grep -oE "^${2}:[[:space:]]*Array\[[0-9]+" "$1" | grep -oE '[0-9]+$' | head -1
}

HP=lib/htmlpaint.ad
PNG=lib/png.ad

# ---- hp_fb: exactly HP_MAX_W*HP_MAX_H*3, and <= 6 MB ------------------------
HP_MAX_W=$(const_of "$HP" HP_MAX_W)
HP_MAX_H=$(const_of "$HP" HP_MAX_H)
HP_FB=$(arr_of "$HP" hp_fb)
HP_FB_CAP=6000000                      # 1000 * 2000 * 3

if [ -z "$HP_MAX_W" ] || [ -z "$HP_MAX_H" ] || [ -z "$HP_FB" ]; then
    bad "could not parse HP_MAX_W/HP_MAX_H/hp_fb from $HP"
else
    want=$(( HP_MAX_W * HP_MAX_H * 3 ))
    if [ "$HP_FB" -eq "$want" ]; then
        pass "hp_fb ($HP_FB) == HP_MAX_W*HP_MAX_H*3 ($want)"
    else
        bad "hp_fb ($HP_FB) != HP_MAX_W*HP_MAX_H*3 ($want) — keep them in sync"
    fi
    if [ "$HP_FB" -le "$HP_FB_CAP" ]; then
        pass "hp_fb ($HP_FB) <= cap ($HP_FB_CAP)"
    else
        bad "hp_fb ($HP_FB) exceeds cap ($HP_FB_CAP) — the paint fb re-inflated"
    fi
    # HP_MAX_H must still cover the tallest laid-out fixture (~1669px) with margin.
    if [ "$HP_MAX_H" -ge 1800 ]; then
        pass "HP_MAX_H ($HP_MAX_H) still covers the tallest fixture (~1669px)"
    else
        bad "HP_MAX_H ($HP_MAX_H) too small — tall fixtures would clip"
    fi
fi

# ---- png scratch: each buffer <= the 1920x1080 cap (~8.5 MB) ----------------
# These are intentionally sized for a full-desktop (1920x1080) hamview capture
# (task #266); they must not grow past that, but must also stay big enough for
# it, so we assert an upper cap only.
PNG_CAP=8500000
for b in png_raw png_out idat_buf; do
    v=$(arr_of "$PNG" "$b")
    if [ -z "$v" ]; then
        bad "could not parse $b from $PNG"
    elif [ "$v" -le "$PNG_CAP" ]; then
        pass "$b ($v) <= cap ($PNG_CAP)"
    else
        bad "$b ($v) exceeds cap ($PNG_CAP) — PNG decode scratch re-inflated"
    fi
done

if [ "$fail" -eq 0 ]; then
    echo "[hp-bounds] ALL PASS"
    exit 0
fi
echo "[hp-bounds] FAILURES present"
exit 1
