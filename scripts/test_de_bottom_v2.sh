#!/usr/bin/env bash
# scripts/test_de_bottom_v2.sh — DE bottom-panel structural guard.
#
# Hamnix's MATE-mirror DE ships a multi-panel layout: a TOP bar plus a BOTTOM
# window-list panel. Both are now produced by the single config-driven
# user/hampanelscene.ad (it creates one window per configured panel and pins
# each to its own screen edge), SUPERSEDING the legacy standalone
# user/hambottom.ad (source kept, no longer spawned). The shipped default
# layout (etc/panel.conf) MUST include a bottom-edge panel so the window-list
# strip is present out of the box.
#
# This guard pins the load-bearing links:
#   1. hampanelscene supports a bottom-edge panel (per-edge placement).
#   2. The window list is read from /dev/wsys/session (so it tracks live wins).
#   3. The shipped etc/panel.conf declares a bottom-edge panel by default.
#
# Pass marker: PASS: DE bottom panel intact
# Fail marker: FAIL: <which link broke>

set -euo pipefail

PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

PANEL_SRC="user/hampanelscene.ad"
PANEL_CONF="etc/panel.conf"

fail=0
fail_link() {
    echo "FAIL: $1" >&2
    fail=1
}

for f in "$PANEL_SRC" "$PANEL_CONF"; do
    if [ ! -f "$f" ]; then
        echo "FAIL: $f missing" >&2
        exit 1
    fi
done

# --- Link 1: hampanelscene supports a bottom-edge panel --------------
if ! grep -qiE '\bbottom\b' "$PANEL_SRC"; then
    fail_link "link 1 (hampanelscene.ad): bottom-edge placement is gone — no bottom panel can render"
fi

# --- Link 2: window-list source -------------------------------------
if ! grep -q "/dev/wsys/windows" "$PANEL_SRC"; then
    fail_link "link 2 (hampanelscene.ad): /dev/wsys/windows is not read — window list won't track live windows"
fi

# --- Link 3: shipped default declares a bottom-edge panel ------------
# Accept either the block form (`edge bottom`) or legacy (`position bottom`).
if ! grep -qiE '(^|[[:space:]])(edge|position)[[:space:]]+bottom([[:space:]]|$)' "$PANEL_CONF"; then
    fail_link "link 3 (etc/panel.conf): no bottom-edge panel declared — the default layout ships without the window-list strip"
fi

if [ "$fail" -ne 0 ]; then
    echo "FAIL: DE bottom-panel guard tripped (see link(s) above)" >&2
    exit 1
fi

echo "PASS: DE bottom panel intact"
exit 0
