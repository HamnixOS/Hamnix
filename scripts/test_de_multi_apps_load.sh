#!/usr/bin/env bash
# scripts/test_de_multi_apps_load.sh — measure cursor refresh while
# multiple apps are open at the same time. This is the user's stated
# requirement: "Opening up several apps all at once and maintaining
# the mouse refresh rate."
#
# Wraps scripts/test_de_mouse_refresh.sh with APPS_TO_OPEN bumped to
# a heavier load (4 hamterms vs the default 3) and a longer settle
# window so the freshly-spawned terminals have time to first-paint
# before the cursor refresh is measured. Same frame-difference metric.
#
# Env overrides:
#   APPS_TO_OPEN    spawned hamterms     (default: 4)
#   PAINT_WAIT      pre-test settle s    (default: 12)
#   WINDOW_S        measurement window s (default: 5)
#   MOUSE_HZ        injected move rate   (default: 20)
#   OUT_REPORT      report path          (default: build/de_multi_apps_load.txt)

set -uo pipefail

PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

export APPS_TO_OPEN="${APPS_TO_OPEN:-4}"
export PAINT_WAIT="${PAINT_WAIT:-12}"
export WINDOW_S="${WINDOW_S:-5}"
export MOUSE_HZ="${MOUSE_HZ:-20}"
export OUT_REPORT="${OUT_REPORT:-build/de_multi_apps_load.txt}"

echo "[test_de_multi_apps_load] running mouse_refresh harness with APPS_TO_OPEN=$APPS_TO_OPEN"
exec bash "$PROJ_ROOT/scripts/test_de_mouse_refresh.sh"
