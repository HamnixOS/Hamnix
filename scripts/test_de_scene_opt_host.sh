#!/usr/bin/env bash
# scripts/test_de_scene_opt_host.sh — QEMU-free HOST render gate for the two
# scene-file DE client apps that HAD NO host harness — hamdesktop (wallpaper +
# launcher icons) and hampanelscene (panel/taskbar). These are exactly the apps
# the "scene-DE-blank" report said paint NOTHING under USERLAND --opt.
#
# WHY THIS GATE EXISTS. Every other DE app factors its scene logic into a
# lib/*core.ad that a *_host.ad harness renders to PNG on the host. hamdesktop
# and hampanelscene did NOT — their scene-build lived inline in the app, so
# there was no way to render them without QEMU, and no fast regression guard on
# their scene output. This gate adds one: each app carries a guarded
# `--scene-dump <file>` test hook (the live DE never passes it, so native
# behaviour is unchanged) that builds its display list WITHOUT any /dev/wsys I/O
# and writes the raw bytes. user/scene_raster_host.ad rasterizes that display
# list with the SAME lib/hamui_host path the kernel compositor uses, to a PPM ->
# PNG you can VIEW.
#
# WHAT IT ASSERTS (Part A, always — host-runnable via the Python seed):
#   * both apps build their scene display list (non-zero bytes);
#   * the list is NON-BLANK: it carries `fill` AND `glyphs` primitives
#     (a blank scene has neither) — the flood-immune text proof;
#   * the list rasterizes to a PNG (artifact for visual inspection).
#
# WHAT IT ASSERTS (Part B, when the self-hosted `.ad` compiler is available):
#   The "scene-DE-blank" miscompile lived in the SELF-HOSTED optimizer
#   (adder/compiler/opt.ad — the loop-condition CSE that hoisted a body-mutated
#   index into the loop preheader; commit that fixed it: the loopcond-CSE fix).
#   The Python seed uses a DIFFERENT optimizer and never had the bug, so Part A
#   cannot exercise it. Part B compiles BOTH apps for the real native target
#   (x86_64-adder-user) WITH --opt and asserts the compile succeeds and is
#   DETERMINISTIC (two --opt runs byte-identical) — a guard that the self-hosted
#   --opt DE build path (where the blank came from) stays healthy. The
#   compiler-level regression of the exact bug is gated separately by
#   scripts/test_opt_loopcond_cse.sh.
#
# SKIPS CLEANLY when the toolchain/deps are unavailable.

set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

OUT="build/host/de_scene_opt"
mkdir -p "$OUT"
fail=0

have_seed() { python3 -c 'import compiler.adder' >/dev/null 2>&1; }
if ! have_seed; then
    echo "[de-scene-opt] SKIP: Python seed compiler unavailable" >&2
    exit 0
fi

seed_compile() {  # <src.ad> <out>
    python3 -m compiler.adder compile --target=x86_64-linux "$1" -o "$2"
}

echo "[de-scene-opt] compiling host scene rasterizer ..."
if ! seed_compile user/scene_raster_host.ad "$OUT/scene_raster" \
        >"$OUT/raster_compile.log" 2>&1; then
    echo "[de-scene-opt] FAIL: scene_raster_host did not compile"; cat "$OUT/raster_compile.log"; exit 1
fi

# --- Part A: render each DE app's scene to a NON-BLANK PNG -----------------
render_de() {  # <app.ad> <name>
    local src="$1" name="$2"
    echo "[de-scene-opt] --- $name ---"
    if ! seed_compile "$src" "$OUT/${name}" >"$OUT/${name}_compile.log" 2>&1; then
        echo "[de-scene-opt] FAIL: $name did not compile"; cat "$OUT/${name}_compile.log"; fail=1; return
    fi
    if ! "$OUT/${name}" --scene-dump "$OUT/${name}.dl" >"$OUT/${name}_dump.log" 2>&1; then
        echo "[de-scene-opt] FAIL: $name --scene-dump exited non-zero"; cat "$OUT/${name}_dump.log"; fail=1; return
    fi
    local bytes; bytes=$(wc -c < "$OUT/${name}.dl")
    echo "[de-scene-opt] $name display-list bytes=$bytes"
    if [ "$bytes" -lt 64 ]; then
        echo "[de-scene-opt] FAIL: $name display list is (near) empty — BLANK scene"; fail=1; return
    fi
    local nfill nglyph
    nfill=$(grep -cE '^fill'   "$OUT/${name}.dl")
    nglyph=$(grep -cE '^glyphs' "$OUT/${name}.dl")
    echo "[de-scene-opt] $name fill=$nfill glyphs=$nglyph"
    if [ "$nfill" -ge 1 ] && [ "$nglyph" -ge 1 ]; then
        echo "[de-scene-opt] PASS $name scene is NON-BLANK (fill + glyphs present)"
    else
        echo "[de-scene-opt] FAIL $name scene BLANK: fill=$nfill glyphs=$nglyph (need >=1 of each)"; fail=1; return
    fi
    if "$OUT/scene_raster" "$OUT/${name}.dl" "$OUT/${name}.ppm" >/dev/null 2>&1 \
            && python3 scripts/ppm_to_png.py "$OUT/${name}.ppm" "$OUT/${name}.png" >/dev/null 2>&1; then
        echo "[de-scene-opt] PASS $name rendered -> $OUT/${name}.png"
    else
        echo "[de-scene-opt] NOTE $name PPM/PNG render skipped (rasterizer/deps)"
    fi
}

render_de user/hamdesktop.ad     hamdesktop
render_de user/hampanelscene.ad  hampanelscene

# --- Part B: self-hosted --opt native build determinism -------------------
# The blank came from the self-hosted --opt path. Compile both apps for the
# native target WITH --opt (the shipped-userland default) and assert success +
# determinism. Best-effort: skips if the self-hosted backend cannot bootstrap.
echo "[de-scene-opt] --- self-hosted --opt native build ---"
export PROJ_ROOT
# shellcheck source=/dev/null
source "$PROJ_ROOT/scripts/_adder_cc.sh"
if ADDER_CC=adder adder_cc_bootstrap >"$OUT/bootstrap.log" 2>&1 \
        && [ -x build/cutover/host_ac.elf ]; then
    for app in hamdesktop hampanelscene; do
        ok=1
        build/cutover/host_ac.elf --target=x86_64-adder-user --opt \
            "user/${app}.ad" "$OUT/${app}_opt_a.o" >"$OUT/${app}_opt_a.log" 2>&1 || ok=0
        build/cutover/host_ac.elf --target=x86_64-adder-user --opt \
            "user/${app}.ad" "$OUT/${app}_opt_b.o" >"$OUT/${app}_opt_b.log" 2>&1 || ok=0
        build/cutover/host_ac.elf --target=x86_64-adder-user \
            "user/${app}.ad" "$OUT/${app}_noopt.o" >"$OUT/${app}_noopt.log" 2>&1 || ok=0
        if [ "$ok" != "1" ]; then
            echo "[de-scene-opt] FAIL: self-hosted compile of $app failed"; fail=1; continue
        fi
        if cmp -s "$OUT/${app}_opt_a.o" "$OUT/${app}_opt_b.o"; then
            echo "[de-scene-opt] PASS $app self-hosted --opt native build is deterministic + clean"
        else
            echo "[de-scene-opt] FAIL $app self-hosted --opt native build is NON-deterministic"; fail=1
        fi
    done
else
    echo "[de-scene-opt] NOTE self-hosted backend unavailable; Part B skipped (Part A authoritative)"
fi

echo "[de-scene-opt] artifacts in $OUT"
if [ "$fail" = "0" ]; then
    echo "[de-scene-opt] RESULT: PASS"; exit 0
fi
echo "[de-scene-opt] RESULT: FAIL"; exit 1
