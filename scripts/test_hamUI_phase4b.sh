#!/usr/bin/env bash
# scripts/test_hamUI_phase4b.sh — hamUI Phase 4b regression.
#
# Verifies the USERLAND RENDERER `hamUId` (docs/hamUI.md H-§G "Renderer
# lives in userland"). Phase 4a built the kernel-side draw FILE SURFACE;
# this phase consumes it: hamUId reads a window's draw layers, parses
# hamML markup, rasterises (rect/line/text/fb-image) into per-layer RGBA
# buffers, composites them z-ascending into a window-sized RGBA target,
# and emits an AI-readable TEXT DUMP to stdout.
#
# CLI under test:  hamUId render <wid>
#   stdout dump shape:
#     DUMP wid=<w> win=640x480 layers=<n>
#     PIX <x> <y> #rrggbb        (probe grid, step 40px)
#     ART <row of '#'/' '>       (80x30 downscaled ASCII view)
#     DUMP END
#
# What this drives (all on wid 1, the foreground serial-console hamsh):
#   1. mklayer chrome markup
#   2. write a known hamML body into chrome/markup:
#        <rect x=40 y=40 w=120 h=80 fill="#ff0000"/>
#        <text x=200 y=40 fill="#ffffff">HELLO</text>
#   3. run `hamUId render 1`
#   4. assert from the stdout dump that:
#        (a) the rect's red fill appears at a probe pixel INSIDE the rect
#            -> PIX 80 40 #ff0000   (80,40 is inside 40..160 x 40..120)
#        (b) the background colour appears OUTSIDE the rect
#            -> PIX 0 0 #000000     (top-left corner, untouched)
#        (c) the text region rendered non-background glyphs
#            -> the ART view has a '#' somewhere (glyphs drew), and the
#               probe grid shows a non-#000000 pixel in the text band.
#
# Console-output ordering is racy (same effect the phase4a test documents
# at length): a long dump's bytes can interleave with the prompt. The
# renderer logic is what's load-bearing, so the positive assertions grep
# the WHOLE log for line shapes that ONLY the dump can produce.

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf

echo "[test_hamUI_phase4b] (1/4) Build userland"
bash scripts/build_user.sh >/dev/null
bash scripts/build_modules.sh >/dev/null

echo "[test_hamUI_phase4b] (2/4) Build initramfs (default /init = init.elf)"
python3 scripts/build_initramfs.py >/dev/null

echo "[test_hamUI_phase4b] (3/4) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

# Guard against a stale kernel producing a FALSE pass: confirm the
# freshly built userland actually contains hamUId.
if [ ! -s build/user/hamUId.elf ]; then
    echo "[test_hamUI_phase4b] FAIL: build/user/hamUId.elf missing/empty"
    exit 1
fi

echo "[test_hamUI_phase4b] (4/4) Boot QEMU + drive hamUId render"
LOG=$(mktemp)
trap 'rm -f "$LOG"' EXIT

set +e
(
    # 8s boot budget, ~3-4s per command — copied from the phase4a test
    # pattern; hamsh must reach its readline stage before piped
    # keystrokes land or they get dropped under host load.
    sleep 8
    # 1. Create a markup layer named chrome on wid 1.
    printf 'echo "mklayer chrome markup" > /dev/wsys/1/draw/ctl\n'
    sleep 3
    # 2. Write a known hamML body: a red rect + white text. Single
    #    write (no quoting headaches): use printf-free echo with the
    #    body on one line. The shell's echo writes it verbatim.
    printf 'echo "<rect x=40 y=40 w=120 h=80 fill=#ff0000/><text x=200 y=40 fill=#ffffff>HELLO</text>" > /dev/wsys/1/draw/chrome/markup\n'
    sleep 3
    # 3. Read it back (sanity / aids debugging the log).
    printf 'echo MARK_BODY_BEGIN; cat /dev/wsys/1/draw/chrome/markup; echo MARK_BODY_END\n'
    sleep 3
    # 4. Render. The dump goes to stdout (the serial console here).
    printf 'echo MARK_RENDER_BEGIN; hamUId render 1; echo MARK_RENDER_END\n'
    sleep 8
    printf 'exit\n'
    sleep 2
) | timeout 140s qemu-system-x86_64 \
    -kernel "$ELF" \
    -smp 2 \
    -nographic \
    -no-reboot \
    -m 256M \
    -monitor none \
    -serial stdio \
    > "$LOG" 2>&1
rc=$?
set -e

echo "[test_hamUI_phase4b] --- captured output ---"
cat "$LOG"
echo "[test_hamUI_phase4b] --- end output ---"

fail=0

assert_has() {
    local needle="$1" label="$2"
    if grep -aF -q "$needle" "$LOG"; then
        echo "[test_hamUI_phase4b] OK: ${label}"
    else
        echo "[test_hamUI_phase4b] MISS: ${label} (no '${needle}' in log)"
        fail=1
    fi
}

# 0. The dump header proves hamUId ran and enumerated layers.
assert_has "DUMP wid=1 win=640x480 layers=" \
    "hamUId render emitted the dump header (layers enumerated)"

# (a) The rect's red fill at a probe pixel INSIDE the rect.
#     rect spans x:40..160 y:40..120; probe (80,40) is inside.
assert_has "PIX 80 40 #ff0000" \
    "rect red fill (#ff0000) appears at probe pixel (80,40) inside the rect"

# (b) The background colour OUTSIDE the rect (top-left corner).
assert_has "PIX 0 0 #000000" \
    "background (#000000) appears at probe pixel (0,0) outside the rect"

# (c) Text rendered non-background glyphs. The 8x16 mono glyphs for
#     "HELLO" at x=200,y=40 occupy x:200..240 y:40..56 — entirely to the
#     RIGHT of the rect's right edge (x=160), so any non-background pixel
#     in this band is GLYPH ink, never rect fill. hamUId emits a
#     deterministic "REGION text 192 32 160 32 nonbg=<count>" summary so
#     the assertion doesn't depend on the coarse probe grid landing on a
#     specific glyph stroke. count > 0 proves text rasterised.
region_line="$(grep -aE '^REGION text ' "$LOG" | head -n1)"
text_nonbg=0
if [ -n "$region_line" ]; then
    cnt="$(printf '%s' "$region_line" | grep -aoE 'nonbg=[0-9]+' | head -n1 | sed 's/nonbg=//')"
    if [ -n "$cnt" ] && [ "$cnt" -gt 0 ]; then
        text_nonbg=1
    fi
fi
if [ "$text_nonbg" -eq 1 ]; then
    echo "[test_hamUI_phase4b] OK: text band has ${cnt} non-background pixels (glyphs rendered right of the rect)"
else
    echo "[test_hamUI_phase4b] MISS: text band REGION shows no non-background pixels"
    fail=1
fi

# (d) The ASCII-art view rendered at least one non-background cell.
if grep -aE -q '^ART .*#' "$LOG"; then
    echo "[test_hamUI_phase4b] OK: ASCII-art view shows non-background content"
else
    echo "[test_hamUI_phase4b] MISS: ASCII-art view is all background"
    fail=1
fi

# (e) The dump terminated cleanly.
assert_has "DUMP END" "dump terminated with DUMP END"

if [ "$fail" -ne 0 ]; then
    echo "[test_hamUI_phase4b] FAIL (qemu rc=$rc)"
    exit 1
fi

echo "[test_hamUI_phase4b] PASS"
