#!/usr/bin/env bash
# scripts/test_de_panel_v2.sh — DE panel extraction guard.
#
# DE pivot Stage B.4 (per docs/graphical_stack_audit.md): the DE panel
# (taskbar + clock + Applications launcher + applets) used to be drawn
# inline by user/hamUId.ad's daemon_pixel cascade. It now runs as a
# standalone hamui-client app (user/hampanel.ad) that reaches the
# framebuffer via the #442 (c) v2 blit protocol.
#
# This guard pins the three load-bearing links:
#   1. No panel-pixel cases remain inside daemon_pixel.
#   2. user/hampanel.ad exists and negotiates the v2 protocol via
#      hamui_set_protocol_v2() and commits via hamui_v2_commit_rect().
#   3. The compositor spawns /bin/hampanel at startup.
#
# Pass marker: PASS: DE panel extracted to /bin/hampanel
# Fail marker: FAIL: <which link broke>

set -euo pipefail

PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

COMPOSITOR_SRC="user/hamUId.ad"
PANEL_SRC="user/hampanel.ad"
BUILD_SH="scripts/build_user.sh"

fail=0
fail_link() {
    echo "FAIL: $1" >&2
    fail=1
}

for f in "$COMPOSITOR_SRC" "$PANEL_SRC" "$BUILD_SH"; do
    if [ ! -f "$f" ]; then
        echo "FAIL: $f missing" >&2
        exit 1
    fi
done

# --- Link 1: panel-pixel cases gone from daemon_pixel ----------------
# Extract the daemon_pixel function body and assert the load-bearing
# panel-drawing tokens that used to live there are no longer present.
# We slice from the `def daemon_pixel(` line up to the next top-level
# `def ` so we only check inside the function body.
pixel_body=$(awk '
    /^def[[:space:]]+daemon_pixel[[:space:]]*\(/ { inside=1; print; next }
    /^def[[:space:]]/ { if (inside) { inside=0 } }
    inside { print }
' "$COMPOSITOR_SRC")

# These were inline panel-drawing dispatches inside daemon_pixel; if any
# come back, the extraction regressed.
for tok in "on_panel_y(y)" "menubar_btn_at(x, y)" "taskbar_btn_x(tbi)" \
           "pager_x0(tb_scr_w)" "clock_x" "CLOCK_HOVER" "notif_x0(" \
           "statnot_x0(" "winsel_btn_x(" "sd_btn_x0("; do
    if echo "$pixel_body" | grep -qF "$tok"; then
        fail_link "link 1 (daemon_pixel): panel-pixel token '$tok' is still inline — panel was not extracted"
    fi
done

# Be defensive: also assert the extraction marker comment is present.
# (Check directly against the file inside the daemon_pixel span — going
# through `echo "$pixel_body" | grep` proved flaky for large bodies.)
if ! grep -q "EXTRACTED to /bin/hampanel" "$COMPOSITOR_SRC"; then
    fail_link "link 1 (daemon_pixel): extraction marker comment is gone — a refactor may have re-inlined the panel"
fi

# --- Link 2: hampanel uses the v2 blit protocol ----------------------
# The keystone payoff: hampanel MUST call hamui_set_protocol_v2 (so the
# compositor flips the per-window protocol version byte to 2) and MUST
# call hamui_v2_commit_rect (so the rio 'B'+'D' verbs actually carry
# pixels to /dev/wsys/<wid>/draw/ctl). Without both, hampanel renders
# nothing and the pivot is paper-only.
if ! grep -q "hamui_set_protocol_v2(" "$PANEL_SRC"; then
    fail_link "link 2 (hampanel.ad): hamui_set_protocol_v2() is not called — panel never negotiates the v2 protocol"
fi
if ! grep -q "hamui_v2_commit_rect(" "$PANEL_SRC"; then
    fail_link "link 2 (hampanel.ad): hamui_v2_commit_rect() is not called — panel never ships a 'B'+'D' blit"
fi
if ! grep -q "/dev/wsys/session" "$PANEL_SRC"; then
    fail_link "link 2 (hampanel.ad): /dev/wsys/session is not read — panel won't track the live window list"
fi
if ! grep -q "/proc/realtime" "$PANEL_SRC"; then
    fail_link "link 2 (hampanel.ad): /proc/realtime is not read — clock won't advance"
fi

# --- Link 3: compositor spawns /bin/hampanel -------------------------
if ! grep -q '"/bin/hampanel"' "$COMPOSITOR_SRC"; then
    fail_link "link 3 (hamUId.ad): /bin/hampanel is not spawned at startup — the panel never appears on screen"
fi

# --- Link 4: hampanel is registered in the build ---------------------
if ! grep -q "build_adder_user hampanel" "$BUILD_SH"; then
    fail_link "link 4 (build_user.sh): hampanel is not registered — binary will not be built/staged"
fi

if [ "$fail" -ne 0 ]; then
    echo "FAIL: DE panel extraction guard tripped (see link(s) above)" >&2
    exit 1
fi

echo "PASS: DE panel extracted to /bin/hampanel"
exit 0
