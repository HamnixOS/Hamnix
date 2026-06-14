#!/usr/bin/env bash
# scripts/test_de_snap_v2.sh — DE pivot wave 1 (round 2) structural
# guard: the snap icon badge layer is no longer drawn by
# daemon_pixel's dpix_root_icons call. It now lives in /bin/hamsnap, a
# v2 client that reads its model from /dev/wsys/snap and is woken by
# writes to /dev/wsys/snap/show.
#
# Pass marker:  PASS: snap v2 extraction intact
# Fail marker:  FAIL: <which link broke>

set -euo pipefail

PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

KERN_SRC="sys/src/9/port/devwsys.ad"
NAMEC_SRC="sys/src/9/port/namec.ad"
HAMUID_SRC="user/hamUId.ad"
SNAP_SRC="user/hamsnap.ad"
BUILD_SRC="scripts/build_user.sh"

fail=0
fail_link() {
    echo "FAIL: $1" >&2
    fail=1
}

for f in "$KERN_SRC" "$NAMEC_SRC" "$HAMUID_SRC" "$SNAP_SRC" "$BUILD_SRC"; do
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
if grep -qE "if[[:space:]]+SNAP_PREVIEW_ON" <<< "$daemon_pixel_body"; then
    fail_link "link 1 (hamUId.ad): daemon_pixel still gates on SNAP_PREVIEW_ON"
fi
if ! grep -q "snap-zone preview.*EXTRACTED" <<< "$daemon_pixel_body"; then
    fail_link "link 1 (hamUId.ad): the 'snap-zone preview ... EXTRACTED' breadcrumb is gone"
fi

# --- Link 2: hamsnap binary is registered + sources -------------
if ! grep -q "build_adder_user hamsnap" "$BUILD_SRC"; then
    fail_link "link 2 (build_user.sh): hamsnap is not built"
fi
if ! grep -q "hamui_set_protocol_v2" "$SNAP_SRC"; then
    fail_link "link 2 (hamsnap.ad): does NOT call hamui_set_protocol_v2"
fi
if ! grep -q '"/dev/wsys/snap"' "$SNAP_SRC"; then
    fail_link "link 2 (hamsnap.ad): does NOT read /dev/wsys/snap snapshot"
fi
if ! grep -q "hamui_v2_commit_rect" "$SNAP_SRC"; then
    fail_link "link 2 (hamsnap.ad): does NOT call hamui_v2_commit_rect"
fi

# --- Link 3: kernel exposes /dev/wsys/snap + show leaves --------
for sym in "DEV_WSYS_SNAP\b" "DEV_WSYS_SNAP_SHOW"; do
    if ! grep -qE "${sym}" "$NAMEC_SRC"; then
        fail_link "link 3 (namec.ad): DEV constant ${sym} is missing"
    fi
done
for fn in devwsys_snap_read devwsys_snap_show_read devwsys_snap_show_write; do
    if ! grep -qE "def[[:space:]]+${fn}[[:space:]]*\(" "$KERN_SRC"; then
        fail_link "link 3 (devwsys.ad): ${fn}() definition is missing"
    fi
    if ! grep -q "${fn}" "$NAMEC_SRC"; then
        fail_link "link 3 (namec.ad): ${fn} is not wired into the dispatcher"
    fi
done
if ! grep -q '"snap/show"' "$NAMEC_SRC"; then
    fail_link "link 3 (namec.ad): snap/show path is not resolved"
fi
if ! grep -q '"snap"' "$NAMEC_SRC"; then
    fail_link "link 3 (namec.ad): snap path is not resolved"
fi
if ! grep -E "_wsys_ctl_word_eq" "$KERN_SRC" | grep -q '"snap"'; then
    fail_link "link 3 (devwsys.ad): /dev/wsys/ctl 'snap' verb is missing"
fi

# --- Link 4: compositor publishes, spawns, and pokes ---------------
for fn in snap_publish_snapshot snap_spawn snap_poke_show snap_publish_if_changed; do
    if ! grep -qE "def[[:space:]]+${fn}[[:space:]]*\(" "$HAMUID_SRC"; then
        fail_link "link 4 (hamUId.ad): ${fn}() definition is missing"
    fi
done
if ! grep -q "snap_spawn(" "$HAMUID_SRC"; then
    fail_link "link 4 (hamUId.ad): snap_spawn is never called"
fi
if ! grep -q '"/bin/hamsnap"' "$HAMUID_SRC"; then
    fail_link "link 4 (hamUId.ad): the compositor does NOT spawn /bin/hamsnap"
fi
post_present_body=$(awk '
    /^def[[:space:]]+post_present_overlays[[:space:]]*\(/ { inside=1; print; next }
    /^def[[:space:]]/ { if (inside) { inside=0 } }
    inside { print }
' "$HAMUID_SRC")
if ! grep -q "snap_publish_if_changed()" <<< "$post_present_body"; then
    fail_link "link 4 (hamUId.ad): post_present_overlays does NOT call snap_publish_if_changed"
fi

# --- Link 5: publish path uses the kernel files --------------------
pub_body=$(awk '
    /^def[[:space:]]+snap_publish_snapshot[[:space:]]*\(/ { inside=1; print; next }
    /^def[[:space:]]/ { if (inside) { inside=0 } }
    inside { print }
' "$HAMUID_SRC")
if ! grep -q '"/dev/wsys/ctl"' <<< "$pub_body"; then
    fail_link "link 5 (hamUId.ad): snap_publish_snapshot does NOT write /dev/wsys/ctl"
fi
if ! grep -q '"snap "' <<< "$pub_body"; then
    fail_link "link 5 (hamUId.ad): snap_publish_snapshot does NOT emit the 'snap' verb"
fi
poke_body=$(awk '
    /^def[[:space:]]+snap_poke_show[[:space:]]*\(/ { inside=1; print; next }
    /^def[[:space:]]/ { if (inside) { inside=0 } }
    inside { print }
' "$HAMUID_SRC")
if ! grep -q '"/dev/wsys/snap/show"' <<< "$poke_body"; then
    fail_link "link 5 (hamUId.ad): snap_poke_show does NOT write /dev/wsys/snap/show"
fi

if [ "$fail" -ne 0 ]; then
    echo "FAIL: snap v2 extraction BROKEN (see link(s) above)" >&2
    exit 1
fi

echo "PASS: snap v2 extraction intact"
exit 0
