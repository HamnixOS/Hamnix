#!/usr/bin/env bash
# scripts/test_de_bottom_v2.sh — DE bottom-panel structural guard.
#
# Hamnix's MATE-mirror DE has a top panel (/bin/hampanel) and a BOTTOM
# panel (/bin/hambottom): Show Desktop button + window-list strip +
# 1..4 workspace switcher. Both are hamui v2 clients that paint via the
# #442 (c) v2 blit protocol.
#
# This guard pins the load-bearing links:
#   1. user/hambottom.ad exists and negotiates the v2 protocol via
#      hamui_set_protocol_v2() + ships pixels via hamui_v2_commit_rect().
#   2. The bottom panel reads the live window list from /dev/wsys/session.
#   3. The compositor spawns /bin/hambottom at startup.
#   4. /bin/hambottom is registered in scripts/build_user.sh.
#
# Pass marker: PASS: DE bottom panel intact
# Fail marker: FAIL: <which link broke>

set -euo pipefail

PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

COMPOSITOR_SRC="user/hamUId.ad"
BOTTOM_SRC="user/hambottom.ad"
BUILD_SH="scripts/build_user.sh"

fail=0
fail_link() {
    echo "FAIL: $1" >&2
    fail=1
}

for f in "$COMPOSITOR_SRC" "$BOTTOM_SRC" "$BUILD_SH"; do
    if [ ! -f "$f" ]; then
        echo "FAIL: $f missing" >&2
        exit 1
    fi
done

# --- Link 1: hambottom uses the v2 blit protocol ---------------------
if ! grep -q "hamui_set_protocol_v2(" "$BOTTOM_SRC"; then
    fail_link "link 1 (hambottom.ad): hamui_set_protocol_v2() not called — bottom panel never negotiates v2"
fi
if ! grep -q "hamui_v2_commit_rect(" "$BOTTOM_SRC"; then
    fail_link "link 1 (hambottom.ad): hamui_v2_commit_rect() not called — bottom panel never ships a 'B'+'D' blit"
fi

# --- Link 2: window list source -------------------------------------
if ! grep -q "/dev/wsys/session" "$BOTTOM_SRC"; then
    fail_link "link 2 (hambottom.ad): /dev/wsys/session is not read — window list won't track live windows"
fi

# --- Link 3: MATE-shape elements (Show Desktop + workspace switcher) -
# These keep us honest about WHAT the bottom panel is: not just an empty
# strip. If somebody guts the file, the test breaks.
if ! grep -qE "SD_BTN_W|_paint_show_desktop" "$BOTTOM_SRC"; then
    fail_link "link 3 (hambottom.ad): Show Desktop button is gone"
fi
if ! grep -qE "WS_COUNT|_paint_workspaces" "$BOTTOM_SRC"; then
    fail_link "link 3 (hambottom.ad): workspace switcher is gone"
fi
if ! grep -qE "_paint_winlist|WINLIST_X" "$BOTTOM_SRC"; then
    fail_link "link 3 (hambottom.ad): window-list region is gone"
fi

# --- Link 4: compositor spawns /bin/hambottom ------------------------
if ! grep -q '"/bin/hambottom"' "$COMPOSITOR_SRC"; then
    fail_link "link 4 (hamUId.ad): /bin/hambottom is not spawned at startup — bottom panel never appears"
fi

# --- Link 5: hambottom is registered in the build --------------------
if ! grep -q "build_adder_user hambottom" "$BUILD_SH"; then
    fail_link "link 5 (build_user.sh): hambottom is not registered — binary will not be built/staged"
fi

if [ "$fail" -ne 0 ]; then
    echo "FAIL: DE bottom-panel guard tripped (see link(s) above)" >&2
    exit 1
fi

echo "PASS: DE bottom panel intact"
exit 0
