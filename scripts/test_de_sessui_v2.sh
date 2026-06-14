#!/usr/bin/env bash
# scripts/test_de_sessui_v2.sh — DE pivot wave 8 structural guard:
# the modal "End Session" dialog (Lock Screen / Log Out / Shut Down /
# Cancel) is no longer drawn by the daemon_pixel monolith. It now lives
# in /bin/hamsessui, a separate-process v2 client that reads its model
# from /dev/wsys/sessui and is woken by writes to /dev/wsys/sessui/show.
# The compositor (user/hamUId.ad) publishes the (open, hover) model on
# every dialog mutation and pokes the show serial.
#
# Pass marker:  PASS: sessui v2 extraction intact
# Fail marker:  FAIL: <which link broke>

set -euo pipefail

PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

KERN_SRC="sys/src/9/port/devwsys.ad"
NAMEC_SRC="sys/src/9/port/namec.ad"
HAMUID_SRC="user/hamUId.ad"
SESSUI_SRC="user/hamsessui.ad"
BUILD_SRC="scripts/build_user.sh"

fail=0
fail_link() {
    echo "FAIL: $1" >&2
    fail=1
}

for f in "$KERN_SRC" "$NAMEC_SRC" "$HAMUID_SRC" "$SESSUI_SRC" "$BUILD_SRC"; do
    if [ ! -f "$f" ]; then
        echo "FAIL: $f missing" >&2
        exit 1
    fi
done

# --- Link 1: session-pixel paths are GONE from daemon_pixel ---------
# The legacy modal dialog fanned out an ~58-line cascade inside
# daemon_pixel, keyed on SESSION_OPEN. If any of its render bindings
# (SESSION_W/SESSION_PAD/SESSION_BTN_H/SESSION_ROWS/session_row_label
# rendering) still appear inside daemon_pixel, the renderer regressed
# back to the monolith.
daemon_pixel_body=$(awk '
    /^def[[:space:]]+daemon_pixel[[:space:]]*\(/ { inside=1; print; next }
    /^def[[:space:]]/ { if (inside) { inside=0 } }
    inside { print }
' "$HAMUID_SRC")
if [ -z "$daemon_pixel_body" ]; then
    fail_link "link 1 (hamUId.ad): daemon_pixel() not found - is it renamed?"
fi
for sym in "SESSION_W\b" "SESSION_PAD\b" "SESSION_BTN_H" "SESSION_ROWS" "session_row_label"; do
    if grep -qE "$sym" <<< "$daemon_pixel_body"; then
        fail_link "link 1 (hamUId.ad): daemon_pixel still references '$sym' - session-dialog rendering did not extract cleanly"
    fi
done
# A breadcrumb comment marking the extraction must remain so a future
# refactor doesn't silently re-inline.
if ! grep -q "Session dialog .*EXTRACTED" <<< "$daemon_pixel_body"; then
    fail_link "link 1 (hamUId.ad): the 'Session dialog ... EXTRACTED' breadcrumb is gone - regression marker missing"
fi

# --- Link 2: hamsessui binary is registered + sources --------------
if ! grep -q "build_adder_user hamsessui" "$BUILD_SRC"; then
    fail_link "link 2 (build_user.sh): hamsessui is not built - the binary won't ship in the initramfs"
fi
# hamsessui must opt into v2 + read the snapshot.
if ! grep -q "hamui_set_protocol_v2" "$SESSUI_SRC"; then
    fail_link "link 2 (hamsessui.ad): does NOT call hamui_set_protocol_v2 - it isn't a v2 client"
fi
if ! grep -q '"/dev/wsys/sessui"' "$SESSUI_SRC"; then
    fail_link "link 2 (hamsessui.ad): does NOT read /dev/wsys/sessui snapshot - the model source is missing"
fi
# It must commit dirty rects via the v2 wire protocol.
if ! grep -q "hamui_v2_commit_rect" "$SESSUI_SRC"; then
    fail_link "link 2 (hamsessui.ad): does NOT call hamui_v2_commit_rect - no pixels reach the kernel backbuffer"
fi

# --- Link 3: kernel exposes /dev/wsys/sessui + show leaves ----------
for sym in "DEV_WSYS_SESSUI\b" "DEV_WSYS_SESSUI_SHOW"; do
    if ! grep -qE "${sym}" "$NAMEC_SRC"; then
        fail_link "link 3 (namec.ad): DEV constant ${sym} is missing"
    fi
done
for fn in devwsys_sessui_read devwsys_sessui_show_read devwsys_sessui_show_write; do
    if ! grep -qE "def[[:space:]]+${fn}[[:space:]]*\(" "$KERN_SRC"; then
        fail_link "link 3 (devwsys.ad): ${fn}() definition is missing"
    fi
    if ! grep -q "${fn}" "$NAMEC_SRC"; then
        fail_link "link 3 (namec.ad): ${fn} is not wired into the dispatcher"
    fi
done
if ! grep -q '"sessui/show"' "$NAMEC_SRC"; then
    fail_link "link 3 (namec.ad): sessui/show path is not resolved"
fi
if ! grep -q '"sessui"' "$NAMEC_SRC"; then
    fail_link "link 3 (namec.ad): sessui path is not resolved"
fi
# The /dev/wsys/ctl `sessui` verb is how hamUId publishes the model.
if ! grep -E "_wsys_ctl_word_eq" "$KERN_SRC" | grep -q '"sessui"'; then
    fail_link "link 3 (devwsys.ad): /dev/wsys/ctl 'sessui' verb is missing - the compositor can't publish the model"
fi

# --- Link 4: compositor publishes, spawns, and pokes ---------------
for fn in sessui_publish_snapshot sessui_spawn sessui_poke_show sessui_publish_if_changed; do
    if ! grep -qE "def[[:space:]]+${fn}[[:space:]]*\(" "$HAMUID_SRC"; then
        fail_link "link 4 (hamUId.ad): ${fn}() definition is missing"
    fi
done
# publish + poke must fire from session_open (the modal becomes visible).
session_open_body=$(awk '
    /^def[[:space:]]+session_open[[:space:]]*\(/ { inside=1; print; next }
    /^def[[:space:]]/ { if (inside) { inside=0 } }
    inside { print }
' "$HAMUID_SRC")
if [ -z "$session_open_body" ]; then
    fail_link "link 4 (hamUId.ad): session_open() not found"
fi
if ! grep -q "sessui_publish_snapshot()" <<< "$session_open_body"; then
    fail_link "link 4 (hamUId.ad): session_open() does NOT call sessui_publish_snapshot - hamsessui won't see the dialog open"
fi
if ! grep -q "sessui_poke_show()" <<< "$session_open_body"; then
    fail_link "link 4 (hamUId.ad): session_open() does NOT call sessui_poke_show - the client never gets woken"
fi
# spawn must be called from daemon startup.
if ! grep -q "sessui_spawn(" "$HAMUID_SRC"; then
    fail_link "link 4 (hamUId.ad): sessui_spawn is never called - the client is never launched"
fi
# It must spawn the SEPARATE-PROCESS hamsessui binary, not draw inline.
if ! grep -q '"/bin/hamsessui"' "$HAMUID_SRC"; then
    fail_link "link 4 (hamUId.ad): the compositor does NOT spawn /bin/hamsessui - extraction is just a comment, not a behaviour change"
fi
# publish_if_changed must run in the per-frame overlay path.
post_present_body=$(awk '
    /^def[[:space:]]+post_present_overlays[[:space:]]*\(/ { inside=1; print; next }
    /^def[[:space:]]/ { if (inside) { inside=0 } }
    inside { print }
' "$HAMUID_SRC")
if ! grep -q "sessui_publish_if_changed()" <<< "$post_present_body"; then
    fail_link "link 4 (hamUId.ad): post_present_overlays does NOT call sessui_publish_if_changed - hover updates never reach the client"
fi

# --- Link 5: publish path uses the kernel files --------------------
pub_body=$(awk '
    /^def[[:space:]]+sessui_publish_snapshot[[:space:]]*\(/ { inside=1; print; next }
    /^def[[:space:]]/ { if (inside) { inside=0 } }
    inside { print }
' "$HAMUID_SRC")
if ! grep -q '"/dev/wsys/ctl"' <<< "$pub_body"; then
    fail_link "link 5 (hamUId.ad): sessui_publish_snapshot does NOT write /dev/wsys/ctl - the model never reaches the kernel"
fi
if ! grep -q '"sessui "' <<< "$pub_body"; then
    fail_link "link 5 (hamUId.ad): sessui_publish_snapshot does NOT emit the 'sessui' verb - the kernel won't accept the payload"
fi
poke_body=$(awk '
    /^def[[:space:]]+sessui_poke_show[[:space:]]*\(/ { inside=1; print; next }
    /^def[[:space:]]/ { if (inside) { inside=0 } }
    inside { print }
' "$HAMUID_SRC")
if ! grep -q '"/dev/wsys/sessui/show"' <<< "$poke_body"; then
    fail_link "link 5 (hamUId.ad): sessui_poke_show does NOT write /dev/wsys/sessui/show - the show-serial never bumps"
fi

if [ "$fail" -ne 0 ]; then
    echo "FAIL: sessui v2 extraction BROKEN (see link(s) above)" >&2
    exit 1
fi

echo "PASS: sessui v2 extraction intact"
exit 0
