#!/usr/bin/env bash
# scripts/test_de_notif_v2.sh — DE pivot wave 7 structural guard:
# the transient notification toast banner (top-right title/body popup that
# fades after ~4 s) is no longer drawn by the daemon_pixel monolith. It
# now lives in /bin/hamnotif, a separate-process v2 client that reads its
# model from /dev/wsys/notif and is woken by writes to /dev/wsys/notif/show.
# The compositor (user/hamUId.ad) publishes the model on every notify_post
# / notify_tick state change, pokes the show serial, and the client
# rasterises whatever active/alpha/title/body the snapshot advertises.
#
# Pass marker:  PASS: notif v2 extraction intact
# Fail marker:  FAIL: <which link broke>

set -euo pipefail

PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

KERN_SRC="sys/src/9/port/devwsys.ad"
NAMEC_SRC="sys/src/9/port/namec.ad"
HAMUID_SRC="user/hamUId.ad"
NOTIF_SRC="user/hamnotif.ad"
BUILD_SRC="scripts/build_user.sh"

fail=0
fail_link() {
    echo "FAIL: $1" >&2
    fail=1
}

for f in "$KERN_SRC" "$NAMEC_SRC" "$HAMUID_SRC" "$NOTIF_SRC" "$BUILD_SRC"; do
    if [ ! -f "$f" ]; then
        echo "FAIL: $f missing" >&2
        exit 1
    fi
done

# --- Link 1: notif-pixel paths are GONE from daemon_pixel -----------
# The legacy banner rendered the per-pixel str_ink cascade over
# notify_title/notify_body, gated on `if NOTIFY_ACTIVE != 0:` inside
# daemon_pixel. If any of its render bindings still appear inside
# daemon_pixel, the renderer regressed back to the monolith.
daemon_pixel_body=$(awk '
    /^def[[:space:]]+daemon_pixel[[:space:]]*\(/ { inside=1; print; next }
    /^def[[:space:]]/ { if (inside) { inside=0 } }
    inside { print }
' "$HAMUID_SRC")
if [ -z "$daemon_pixel_body" ]; then
    fail_link "link 1 (hamUId.ad): daemon_pixel() not found - is it renamed?"
fi
for sym in "NOTIFY_ACTIVE" "notify_title" "notify_body" "notify_alpha" \
           "NOTIFY_BORDER_R"; do
    if grep -qE "$sym" <<< "$daemon_pixel_body"; then
        fail_link "link 1 (hamUId.ad): daemon_pixel still references '$sym' - notif banner rendering did not extract cleanly"
    fi
done
# A breadcrumb comment marking the extraction must remain so a future
# refactor doesn't silently re-inline.
if ! grep -q "notification banner rendering EXTRACTED" <<< "$daemon_pixel_body"; then
    fail_link "link 1 (hamUId.ad): the 'notification banner rendering EXTRACTED' breadcrumb is gone - regression marker missing"
fi

# --- Link 2: hamnotif binary is registered + sources ----------------
if ! grep -q "build_adder_user hamnotif" "$BUILD_SRC"; then
    fail_link "link 2 (build_user.sh): hamnotif is not built - the binary won't ship in the initramfs"
fi
# hamnotif must opt into v2 + read the snapshot.
if ! grep -q "hamui_set_protocol_v2" "$NOTIF_SRC"; then
    fail_link "link 2 (hamnotif.ad): does NOT call hamui_set_protocol_v2 - it isn't a v2 client"
fi
if ! grep -q '"/dev/wsys/notif"' "$NOTIF_SRC"; then
    fail_link "link 2 (hamnotif.ad): does NOT read /dev/wsys/notif snapshot - the model source is missing"
fi
# It must commit dirty rects via the v2 wire protocol.
if ! grep -q "hamui_v2_commit_rect" "$NOTIF_SRC"; then
    fail_link "link 2 (hamnotif.ad): does NOT call hamui_v2_commit_rect - no pixels reach the kernel backbuffer"
fi

# --- Link 3: kernel exposes /dev/wsys/notif + show ------------------
for sym in "DEV_WSYS_NOTIF\b" "DEV_WSYS_NOTIF_SHOW"; do
    if ! grep -qE "${sym}" "$NAMEC_SRC"; then
        fail_link "link 3 (namec.ad): DEV constant ${sym} is missing"
    fi
done
for fn in devwsys_notif_read devwsys_notif_show_read devwsys_notif_show_write; do
    if ! grep -qE "def[[:space:]]+${fn}[[:space:]]*\(" "$KERN_SRC"; then
        fail_link "link 3 (devwsys.ad): ${fn}() definition is missing"
    fi
    if ! grep -q "${fn}" "$NAMEC_SRC"; then
        fail_link "link 3 (namec.ad): ${fn} is not wired into the dispatcher"
    fi
done
if ! grep -q '"notif/show"' "$NAMEC_SRC"; then
    fail_link "link 3 (namec.ad): notif/show path is not resolved"
fi
if ! grep -q '"notif"' "$NAMEC_SRC"; then
    fail_link "link 3 (namec.ad): notif path is not resolved"
fi
# The /dev/wsys/ctl `notif` verb is how hamUId publishes the model.
if ! grep -E "_wsys_ctl_word_eq" "$KERN_SRC" | grep -q '"notif"'; then
    fail_link "link 3 (devwsys.ad): /dev/wsys/ctl 'notif' verb is missing - the compositor can't publish the model"
fi

# --- Link 4: compositor publishes, spawns, and pokes ----------------
for fn in notif_publish_snapshot notif_spawn notif_poke_show notif_republish_if_changed; do
    if ! grep -qE "def[[:space:]]+${fn}[[:space:]]*\(" "$HAMUID_SRC"; then
        fail_link "link 4 (hamUId.ad): ${fn}() definition is missing"
    fi
done
# publish + poke must fire from notify_post (every new banner) and
# notify_tick (when the banner expires).
for hook in notify_post notify_tick; do
    body=$(awk -v fn="$hook" '
        $0 ~ "^def[[:space:]]+"fn"[[:space:]]*\\(" { inside=1; print; next }
        /^def[[:space:]]/ { if (inside) { inside=0 } }
        inside { print }
    ' "$HAMUID_SRC")
    if [ -z "$body" ]; then
        fail_link "link 4 (hamUId.ad): ${hook}() not found"
        continue
    fi
    if ! grep -q "notif_publish_snapshot()" <<< "$body"; then
        fail_link "link 4 (hamUId.ad): ${hook}() does NOT call notif_publish_snapshot - hamnotif won't see the state change"
    fi
    if ! grep -q "notif_poke_show()" <<< "$body"; then
        fail_link "link 4 (hamUId.ad): ${hook}() does NOT call notif_poke_show - the client never gets woken"
    fi
done
# spawn must be called from daemon startup.
if ! grep -q "notif_spawn(" "$HAMUID_SRC"; then
    fail_link "link 4 (hamUId.ad): notif_spawn is never called - the client is never launched"
fi
# It must spawn the SEPARATE-PROCESS hamnotif binary, not draw inline.
if ! grep -q '"/bin/hamnotif"' "$HAMUID_SRC"; then
    fail_link "link 4 (hamUId.ad): the compositor does NOT spawn /bin/hamnotif - extraction is just a comment, not a behaviour change"
fi
# republish must run in the daemon main loop.
if ! grep -q "notif_republish_if_changed(" "$HAMUID_SRC"; then
    fail_link "link 4 (hamUId.ad): notif_republish_if_changed is never called - the fade-bucket alpha update never reaches the client"
fi

# --- Link 5: publish + poke paths use the kernel files --------------
pub_body=$(awk '
    /^def[[:space:]]+notif_publish_snapshot[[:space:]]*\(/ { inside=1; print; next }
    /^def[[:space:]]/ { if (inside) { inside=0 } }
    inside { print }
' "$HAMUID_SRC")
if ! grep -q '"/dev/wsys/ctl"' <<< "$pub_body"; then
    fail_link "link 5 (hamUId.ad): notif_publish_snapshot does NOT write /dev/wsys/ctl - the model never reaches the kernel"
fi
if ! grep -q '"notif "' <<< "$pub_body"; then
    fail_link "link 5 (hamUId.ad): notif_publish_snapshot does NOT emit the 'notif' verb - the kernel won't accept the payload"
fi
poke_body=$(awk '
    /^def[[:space:]]+notif_poke_show[[:space:]]*\(/ { inside=1; print; next }
    /^def[[:space:]]/ { if (inside) { inside=0 } }
    inside { print }
' "$HAMUID_SRC")
if ! grep -q '"/dev/wsys/notif/show"' <<< "$poke_body"; then
    fail_link "link 5 (hamUId.ad): notif_poke_show does NOT write /dev/wsys/notif/show - the show-serial never bumps"
fi

if [ "$fail" -ne 0 ]; then
    echo "FAIL: notif v2 extraction BROKEN (see link(s) above)" >&2
    exit 1
fi

echo "PASS: notif v2 extraction intact"
exit 0
