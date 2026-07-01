#!/usr/bin/env bash
# scripts/test_de_panel_v2.sh — DE panel structural guard.
#
# The DE panel (taskbar + clock + Applications launcher + applets) runs as a
# standalone hamui-client scene app (user/hampanelscene.ad) that reaches the
# framebuffer via the #442 (c) v2 blit protocol. It SUPERSEDES the legacy
# split user/hampanel.ad + user/hambottom.ad (sources kept, no longer spawned):
# a single config-driven hampanelscene now creates one window per configured
# panel across top/bottom/left/right edges, with right-click panel editing.
#
# This guard pins the load-bearing links:
#   1. No panel-pixel cases remain inline inside hamUId.ad's daemon_pixel.
#   2. user/hampanelscene.ad negotiates v2 (hamui_set_protocol_v2 +
#      hamui_v2_commit_rect), reads the live window list (/dev/wsys/session),
#      parses the panel config (/etc/panel.conf), supports per-edge placement,
#      and implements right-click panel editing (Add/Move/Remove).
#   3. The compositor spawns /bin/hampanelscene at startup.
#   4. hampanelscene is registered in scripts/build_user.sh.
#
# Pass marker: PASS: DE panel intact (hampanelscene)
# Fail marker: FAIL: <which link broke>

set -euo pipefail

PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

COMPOSITOR_SRC="user/hamUId.ad"
PANEL_SRC="user/hampanelscene.ad"
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
pixel_body=$(awk '
    /^def[[:space:]]+daemon_pixel[[:space:]]*\(/ { inside=1; print; next }
    /^def[[:space:]]/ { if (inside) { inside=0 } }
    inside { print }
' "$COMPOSITOR_SRC")

for tok in "on_panel_y(y)" "menubar_btn_at(x, y)" "taskbar_btn_x(tbi)" \
           "pager_x0(tb_scr_w)" "clock_x" "CLOCK_HOVER" "notif_x0(" \
           "statnot_x0(" "winsel_btn_x(" "sd_btn_x0("; do
    if echo "$pixel_body" | grep -qF "$tok"; then
        fail_link "link 1 (daemon_pixel): panel-pixel token '$tok' is still inline — panel was not extracted"
    fi
done

# --- Link 2: hampanelscene is a real config-driven multi-edge scene panel
# It renders via the display-list SCENE protocol (docs/de_scene_file_arch.md),
# not the legacy v2 blit, and reads the live window list from /dev/wsys/windows.
if ! grep -qi "scene" "$PANEL_SRC"; then
    fail_link "link 2 (hampanelscene.ad): no scene-render path — panel never emits a display list"
fi
if ! grep -q "/dev/wsys/windows" "$PANEL_SRC"; then
    fail_link "link 2 (hampanelscene.ad): /dev/wsys/windows is not read — panel won't track the live window list"
fi
if ! grep -q "panel.conf" "$PANEL_SRC"; then
    fail_link "link 2 (hampanelscene.ad): panel.conf is not parsed — multi-panel layout is not config-driven"
fi
# Per-edge placement (top/bottom/left/right) is the MATE-parity payoff.
if ! grep -qiE '\bbottom\b' "$PANEL_SRC" || ! grep -qiE '\bleft\b' "$PANEL_SRC" || ! grep -qiE '\bright\b' "$PANEL_SRC"; then
    fail_link "link 2 (hampanelscene.ad): per-edge placement (bottom/left/right) tokens missing — multi-edge panels lost"
fi
# Right-click panel editing (Add / Move / Remove).
if ! grep -qE 'CTXK_ADD|Add to Panel' "$PANEL_SRC"; then
    fail_link "link 2 (hampanelscene.ad): right-click 'Add to Panel' editing is gone"
fi
if ! grep -qE 'Move|Remove' "$PANEL_SRC"; then
    fail_link "link 2 (hampanelscene.ad): on-widget Move/Remove editing is gone"
fi

# --- Link 3: compositor spawns /bin/hampanelscene --------------------
if ! grep -q '"/bin/hampanelscene"' "$COMPOSITOR_SRC"; then
    fail_link "link 3 (hamUId.ad): /bin/hampanelscene is not spawned at startup — the panel never appears on screen"
fi

# --- Link 4: hampanelscene is registered in the build ----------------
if ! grep -q "build_adder_user hampanelscene" "$BUILD_SH"; then
    fail_link "link 4 (build_user.sh): hampanelscene is not registered — binary will not be built/staged"
fi

# --- Link 5: taskbar is LIVE via a window-set CONTENT hash -----------
# The panel must re-render its taskbar whenever the window SET changes in ANY
# way, not just when the window COUNT changes. Count-only detection missed the
# common live case where an app `newwindow`s (enumerated as the "winN"
# placeholder) and only writes its real `title` a moment later: same count, so
# a freshly-opened app "never appeared" under its real name. The fix hashes the
# raw /dev/wsys/windows snapshot (win_hash, FNV-1a over wids+titles+order) and
# redraws on any change. Guard both the hash and that the loop no longer gates
# the taskbar redraw on a bare count comparison.
if ! grep -q 'win_hash' "$PANEL_SRC"; then
    fail_link "link 5 (hampanelscene.ad): no win_hash — taskbar liveness regressed to count-only detection (title-set-after-map won't refresh)"
fi
if grep -qE '\bn_tasks[[:space:]]*!=[[:space:]]*last_ntasks\b' "$PANEL_SRC"; then
    fail_link "link 5 (hampanelscene.ad): taskbar redraw still gated on count-only (n_tasks != last_ntasks) — same-count window-set changes go unrendered"
fi

if [ "$fail" -ne 0 ]; then
    echo "FAIL: DE panel guard tripped (see link(s) above)" >&2
    exit 1
fi

echo "PASS: DE panel intact (hampanelscene)"
exit 0
