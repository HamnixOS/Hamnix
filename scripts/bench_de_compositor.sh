#!/usr/bin/env bash
# scripts/bench_de_compositor.sh — REPEATABLE host performance benchmark for
# the DE compositor's rasterization / compositing path. Pure host tooling: no
# QEMU, no Hamnix image.
#
# WHAT / WHY
# ==========
# The DE draws by building a text display list (lib/hamscene.ad) that the
# kernel scene compositor (sys/src/9/port/devwsys.ad) rasterizes to /dev/fb.
# lib/hamui_host.ad is the dual-target TWIN of that compositor: it parses the
# SAME display list and rasterizes it to a framebuffer on the dev host, with no
# QEMU. This bench builds a REPRESENTATIVE DE frame (wallpaper + top panel +
# taskbar + three overlapping windows with title bars & body text + desktop
# icons + one image blit) at 1024x768 and times how long hamui_host_rasterize()
# takes to composite one full frame, averaged over many iterations, broken down
# by primitive class (fill rects, AA TrueType glyphs, image blits).
#
# This is the standing BEFORE baseline for the Vulkan-unification work: once the
# DE is routed through the vk spine (a later phase), re-run this EXACT harness
# and compare — the vk backend should be as fast or faster, and the per-class
# breakdown shows which primitives it changed. See docs/de_perf_baseline.md.
#
# The harness does NOT change any DE rendering behavior; it only adds a scene +
# a timing loop over the existing rasterizer.
#
# USAGE:
#   bash scripts/bench_de_compositor.sh              # 100 iters/scene (default)
#   BENCH_DE_ITERS=300 bash scripts/bench_de_compositor.sh   # more iters
#   BENCH_DE_PPM=1 bash scripts/bench_de_compositor.sh       # also dump a PNG
#
# NOTE: this is a MANUAL performance bench, NOT a pass/fail CI gate — the
# absolute ms/frame numbers are host-CPU dependent, so it is deliberately NOT
# registered in scripts/ci_battery_manifest.txt. Compare BEFORE vs AFTER on the
# SAME quiet host.
set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ITERS="${BENCH_DE_ITERS:-100}"
OUT="build/host"
BIN="$OUT/bench_de_host"
mkdir -p "$OUT"

echo "[bench-de] host: $(grep -m1 'model name' /proc/cpuinfo | cut -d: -f2 | sed 's/^ //')"
echo "[bench-de] load: $(uptime | sed 's/.*load average/load average/')"
echo "[bench-de] compiling user/bench_de_host.ad -> $BIN (x86_64-linux) ..."
if ! python3 -m compiler.adder compile --target=x86_64-linux \
        user/bench_de_host.ad -o "$BIN" 2>"$OUT/bench_de_compile.log"; then
    echo "[bench-de] FAIL: harness did not compile"
    cat "$OUT/bench_de_compile.log"; exit 1
fi

PPM_ARG=""
if [ "${BENCH_DE_PPM:-0}" = "1" ]; then
    PPM_ARG="$OUT/bench_de_frame.ppm"
fi

echo "[bench-de] running $ITERS timed iterations per scene ..."
echo
"$BIN" "$ITERS" $PPM_ARG
rc=$?
echo

if [ "${BENCH_DE_PPM:-0}" = "1" ] && [ -f "$PPM_ARG" ]; then
    if python3 scripts/ppm_to_png.py "$PPM_ARG" "$OUT/bench_de_frame.png" \
            >/dev/null 2>&1; then
        echo "[bench-de] wrote $OUT/bench_de_frame.png (representative frame)"
    fi
fi

if [ "$rc" -ne 0 ]; then
    echo "[bench-de] FAIL: harness exited $rc"; exit 1
fi
echo "[bench-de] done. min_ms is the best-of-N frame time; per-class"
echo "[bench-de] composite-only rows subtract the framebuffer-clear cost."
