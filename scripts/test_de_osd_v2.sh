#!/usr/bin/env bash
# scripts/test_de_osd_v2.sh — DE pivot wave 1 (round 2) structural
# guard: the osd icon badge layer is no longer drawn by
# daemon_pixel's dpix_root_icons call. It now lives in /bin/hamosd, a
# v2 client that reads its model from /dev/wsys/osd and is woken by
# writes to /dev/wsys/osd/show.
#
# Pass marker:  PASS: osd v2 extraction intact
# Fail marker:  FAIL: <which link broke>

set -euo pipefail

PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

KERN_SRC="sys/src/9/port/devwsys.ad"
NAMEC_SRC="sys/src/9/port/namec.ad"
HAMUID_SRC="user/hamUId.ad"
OSD_SRC="user/hamosd.ad"
BUILD_SRC="scripts/build_user.sh"

fail=0
fail_link() {
    echo "FAIL: $1" >&2
    fail=1
}

for f in "$KERN_SRC" "$NAMEC_SRC" "$HAMUID_SRC" "$OSD_SRC" "$BUILD_SRC"; do
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
if grep -qE "if[[:space:]]+osd_active\(\)" <<< "$daemon_pixel_body"; then
    fail_link "link 1 (hamUId.ad): daemon_pixel still gates on osd_active()"
fi
if ! grep -q "OSD popup.*EXTRACTED" <<< "$daemon_pixel_body"; then
    fail_link "link 1 (hamUId.ad): the 'OSD popup ... EXTRACTED' breadcrumb is gone"
fi

# --- Link 2: hamosd binary is registered + sources -------------
if ! grep -q "build_adder_user hamosd" "$BUILD_SRC"; then
    fail_link "link 2 (build_user.sh): hamosd is not built"
fi
if ! grep -q "hamui_set_protocol_v2" "$OSD_SRC"; then
    fail_link "link 2 (hamosd.ad): does NOT call hamui_set_protocol_v2"
fi
if ! grep -q '"/dev/wsys/osd"' "$OSD_SRC"; then
    fail_link "link 2 (hamosd.ad): does NOT read /dev/wsys/osd snapshot"
fi
if ! grep -q "hamui_v2_commit_rect" "$OSD_SRC"; then
    fail_link "link 2 (hamosd.ad): does NOT call hamui_v2_commit_rect"
fi

# --- Link 3: kernel exposes /dev/wsys/osd + show leaves --------
for sym in "DEV_WSYS_OSD\b" "DEV_WSYS_OSD_SHOW"; do
    if ! grep -qE "${sym}" "$NAMEC_SRC"; then
        fail_link "link 3 (namec.ad): DEV constant ${sym} is missing"
    fi
done
for fn in devwsys_osd_read devwsys_osd_show_read devwsys_osd_show_write; do
    if ! grep -qE "def[[:space:]]+${fn}[[:space:]]*\(" "$KERN_SRC"; then
        fail_link "link 3 (devwsys.ad): ${fn}() definition is missing"
    fi
    if ! grep -q "${fn}" "$NAMEC_SRC"; then
        fail_link "link 3 (namec.ad): ${fn} is not wired into the dispatcher"
    fi
done
if ! grep -q '"osd/show"' "$NAMEC_SRC"; then
    fail_link "link 3 (namec.ad): osd/show path is not resolved"
fi
if ! grep -q '"osd"' "$NAMEC_SRC"; then
    fail_link "link 3 (namec.ad): osd path is not resolved"
fi
if ! grep -E "_wsys_ctl_word_eq" "$KERN_SRC" | grep -q '"osd"'; then
    fail_link "link 3 (devwsys.ad): /dev/wsys/ctl 'osd' verb is missing"
fi

# --- Link 4: compositor publishes, spawns, and pokes ---------------
for fn in osd_publish_snapshot osd_spawn osd_poke_show osd_publish_if_changed; do
    if ! grep -qE "def[[:space:]]+${fn}[[:space:]]*\(" "$HAMUID_SRC"; then
        fail_link "link 4 (hamUId.ad): ${fn}() definition is missing"
    fi
done
if ! grep -q "osd_spawn(" "$HAMUID_SRC"; then
    fail_link "link 4 (hamUId.ad): osd_spawn is never called"
fi
if ! grep -q '"/bin/hamosd"' "$HAMUID_SRC"; then
    fail_link "link 4 (hamUId.ad): the compositor does NOT spawn /bin/hamosd"
fi
post_present_body=$(awk '
    /^def[[:space:]]+post_present_overlays[[:space:]]*\(/ { inside=1; print; next }
    /^def[[:space:]]/ { if (inside) { inside=0 } }
    inside { print }
' "$HAMUID_SRC")
if ! grep -q "osd_publish_if_changed()" <<< "$post_present_body"; then
    fail_link "link 4 (hamUId.ad): post_present_overlays does NOT call osd_publish_if_changed"
fi

# --- Link 5: publish path uses the kernel files --------------------
pub_body=$(awk '
    /^def[[:space:]]+osd_publish_snapshot[[:space:]]*\(/ { inside=1; print; next }
    /^def[[:space:]]/ { if (inside) { inside=0 } }
    inside { print }
' "$HAMUID_SRC")
if ! grep -q '"/dev/wsys/ctl"' <<< "$pub_body"; then
    fail_link "link 5 (hamUId.ad): osd_publish_snapshot does NOT write /dev/wsys/ctl"
fi
if ! grep -q '"osd "' <<< "$pub_body"; then
    fail_link "link 5 (hamUId.ad): osd_publish_snapshot does NOT emit the 'osd' verb"
fi
poke_body=$(awk '
    /^def[[:space:]]+osd_poke_show[[:space:]]*\(/ { inside=1; print; next }
    /^def[[:space:]]/ { if (inside) { inside=0 } }
    inside { print }
' "$HAMUID_SRC")
if ! grep -q '"/dev/wsys/osd/show"' <<< "$poke_body"; then
    fail_link "link 5 (hamUId.ad): osd_poke_show does NOT write /dev/wsys/osd/show"
fi

if [ "$fail" -ne 0 ]; then
    echo "FAIL: osd v2 extraction BROKEN (see link(s) above)" >&2
    exit 1
fi

echo "PASS: osd v2 extraction intact"
exit 0
