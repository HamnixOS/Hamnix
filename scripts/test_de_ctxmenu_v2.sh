#!/usr/bin/env bash
# scripts/test_de_ctxmenu_v2.sh — DE pivot wave 1 (round 2) structural
# guard: the ctxmenu icon badge layer is no longer drawn by
# daemon_pixel's dpix_root_icons call. It now lives in /bin/hamctxmenu, a
# v2 client that reads its model from /dev/wsys/ctxmenu and is woken by
# writes to /dev/wsys/ctxmenu/show.
#
# Pass marker:  PASS: ctxmenu v2 extraction intact
# Fail marker:  FAIL: <which link broke>

set -euo pipefail

PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

KERN_SRC="sys/src/9/port/devwsys.ad"
NAMEC_SRC="sys/src/9/port/namec.ad"
HAMUID_SRC="user/hamUId.ad"
CTXMENU_SRC="user/hamctxmenu.ad"
BUILD_SRC="scripts/build_user.sh"

fail=0
fail_link() {
    echo "FAIL: $1" >&2
    fail=1
}

for f in "$KERN_SRC" "$NAMEC_SRC" "$HAMUID_SRC" "$CTXMENU_SRC" "$BUILD_SRC"; do
    if [ ! -f "$f" ]; then
        echo "FAIL: $f missing" >&2
        exit 1
    fi
done

# --- Link 1: dpix_root_icons call is GONE from daemon_pixel ---------
daemon_pixel_body=$(awk '
    /^def[[:space:]]+daemon_pixel[[:space:]]*\(/ { inside=1; print; next }
    /^def[[:space:]]/ { if (inside) { inside=0 } }
    inside { print }
' "$HAMUID_SRC")
if [ -z "$daemon_pixel_body" ]; then
    fail_link "link 1 (hamUId.ad): daemon_pixel() not found"
fi
if grep -qE "if[[:space:]]+CTX_OPEN[[:space:]]*!=[[:space:]]*0" <<< "$daemon_pixel_body"; then
    fail_link "link 1 (hamUId.ad): daemon_pixel still gates on CTX_OPEN - ctxmenu rendering did not extract"
fi
if ! grep -q "right-click context menu.*EXTRACTED" <<< "$daemon_pixel_body"; then
    fail_link "link 1 (hamUId.ad): the 'right-click context menu ... EXTRACTED' breadcrumb is gone"
fi

# --- Link 2: hamctxmenu binary is registered + sources -------------
if ! grep -q "build_adder_user hamctxmenu" "$BUILD_SRC"; then
    fail_link "link 2 (build_user.sh): hamctxmenu is not built"
fi
if ! grep -q "hamui_set_protocol_v2" "$CTXMENU_SRC"; then
    fail_link "link 2 (hamctxmenu.ad): does NOT call hamui_set_protocol_v2"
fi
if ! grep -q '"/dev/wsys/ctxmenu"' "$CTXMENU_SRC"; then
    fail_link "link 2 (hamctxmenu.ad): does NOT read /dev/wsys/ctxmenu snapshot"
fi
if ! grep -q "hamui_v2_commit_rect" "$CTXMENU_SRC"; then
    fail_link "link 2 (hamctxmenu.ad): does NOT call hamui_v2_commit_rect"
fi

# --- Link 3: kernel exposes /dev/wsys/ctxmenu + show leaves --------
for sym in "DEV_WSYS_CTXMENU\b" "DEV_WSYS_CTXMENU_SHOW"; do
    if ! grep -qE "${sym}" "$NAMEC_SRC"; then
        fail_link "link 3 (namec.ad): DEV constant ${sym} is missing"
    fi
done
for fn in devwsys_ctxmenu_read devwsys_ctxmenu_show_read devwsys_ctxmenu_show_write; do
    if ! grep -qE "def[[:space:]]+${fn}[[:space:]]*\(" "$KERN_SRC"; then
        fail_link "link 3 (devwsys.ad): ${fn}() definition is missing"
    fi
    if ! grep -q "${fn}" "$NAMEC_SRC"; then
        fail_link "link 3 (namec.ad): ${fn} is not wired into the dispatcher"
    fi
done
if ! grep -q '"ctxmenu/show"' "$NAMEC_SRC"; then
    fail_link "link 3 (namec.ad): ctxmenu/show path is not resolved"
fi
if ! grep -q '"ctxmenu"' "$NAMEC_SRC"; then
    fail_link "link 3 (namec.ad): ctxmenu path is not resolved"
fi
if ! grep -E "_wsys_ctl_word_eq" "$KERN_SRC" | grep -q '"ctxmenu"'; then
    fail_link "link 3 (devwsys.ad): /dev/wsys/ctl 'ctxmenu' verb is missing"
fi

# --- Link 4: compositor publishes, spawns, and pokes ---------------
for fn in ctxmenu_publish_snapshot ctxmenu_spawn ctxmenu_poke_show ctxmenu_publish_if_changed; do
    if ! grep -qE "def[[:space:]]+${fn}[[:space:]]*\(" "$HAMUID_SRC"; then
        fail_link "link 4 (hamUId.ad): ${fn}() definition is missing"
    fi
done
if ! grep -q "ctxmenu_spawn(" "$HAMUID_SRC"; then
    fail_link "link 4 (hamUId.ad): ctxmenu_spawn is never called"
fi
if ! grep -q '"/bin/hamctxmenu"' "$HAMUID_SRC"; then
    fail_link "link 4 (hamUId.ad): the compositor does NOT spawn /bin/hamctxmenu"
fi
post_present_body=$(awk '
    /^def[[:space:]]+post_present_overlays[[:space:]]*\(/ { inside=1; print; next }
    /^def[[:space:]]/ { if (inside) { inside=0 } }
    inside { print }
' "$HAMUID_SRC")
if ! grep -q "ctxmenu_publish_if_changed()" <<< "$post_present_body"; then
    fail_link "link 4 (hamUId.ad): post_present_overlays does NOT call ctxmenu_publish_if_changed"
fi

# --- Link 5: publish path uses the kernel files --------------------
pub_body=$(awk '
    /^def[[:space:]]+ctxmenu_publish_snapshot[[:space:]]*\(/ { inside=1; print; next }
    /^def[[:space:]]/ { if (inside) { inside=0 } }
    inside { print }
' "$HAMUID_SRC")
if ! grep -q '"/dev/wsys/ctl"' <<< "$pub_body"; then
    fail_link "link 5 (hamUId.ad): ctxmenu_publish_snapshot does NOT write /dev/wsys/ctl"
fi
if ! grep -q '"ctxmenu "' <<< "$pub_body"; then
    fail_link "link 5 (hamUId.ad): ctxmenu_publish_snapshot does NOT emit the 'ctxmenu' verb"
fi
poke_body=$(awk '
    /^def[[:space:]]+ctxmenu_poke_show[[:space:]]*\(/ { inside=1; print; next }
    /^def[[:space:]]/ { if (inside) { inside=0 } }
    inside { print }
' "$HAMUID_SRC")
if ! grep -q '"/dev/wsys/ctxmenu/show"' <<< "$poke_body"; then
    fail_link "link 5 (hamUId.ad): ctxmenu_poke_show does NOT write /dev/wsys/ctxmenu/show"
fi

if [ "$fail" -ne 0 ]; then
    echo "FAIL: ctxmenu v2 extraction BROKEN (see link(s) above)" >&2
    exit 1
fi

echo "PASS: ctxmenu v2 extraction intact"
exit 0
