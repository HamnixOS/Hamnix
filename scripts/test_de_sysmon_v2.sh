#!/usr/bin/env bash
# scripts/test_de_sysmon_v2.sh — DE pivot wave 2 structural
# guard: the sysmon icon badge layer is no longer drawn by
# daemon_pixel's dpix_root_dmon call. It now lives in /bin/hamsysmon, a
# v2 client that reads its model from /dev/wsys/sysmon and is woken by
# writes to /dev/wsys/sysmon/show.
#
# Pass marker:  PASS: sysmon v2 extraction intact
# Fail marker:  FAIL: <which link broke>

set -euo pipefail

PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

KERN_SRC="sys/src/9/port/devwsys.ad"
NAMEC_SRC="sys/src/9/port/namec.ad"
HAMUID_SRC="user/hamUId.ad"
SYSMON_SRC="user/hamsysmon.ad"
BUILD_SRC="scripts/build_user.sh"

fail=0
fail_link() {
    echo "FAIL: $1" >&2
    fail=1
}

for f in "$KERN_SRC" "$NAMEC_SRC" "$HAMUID_SRC" "$SYSMON_SRC" "$BUILD_SRC"; do
    if [ ! -f "$f" ]; then
        echo "FAIL: $f missing" >&2
        exit 1
    fi
done

# --- Link 1: dpix_root_dmon call is GONE from daemon_pixel ---------
daemon_pixel_body=$(awk '
    /^def[[:space:]]+daemon_pixel[[:space:]]*\(/ { inside=1; print; next }
    /^def[[:space:]]/ { if (inside) { inside=0 } }
    inside { print }
' "$HAMUID_SRC")
if [ -z "$daemon_pixel_body" ]; then
    fail_link "link 1 (hamUId.ad): daemon_pixel() not found"
fi
if grep -qE "dpix_root_dmon\(" <<< "$daemon_pixel_body"; then
    fail_link "link 1 (hamUId.ad): daemon_pixel still calls dpix_root_dmon - sysmon rendering did not extract"
fi
if ! grep -q "system monitor applet.*EXTRACTED" <<< "$daemon_pixel_body"; then
    fail_link "link 1 (hamUId.ad): the 'system monitor applet ... EXTRACTED' breadcrumb is gone"
fi

# --- Link 2: hamsysmon binary is registered + sources -------------
if ! grep -q "build_adder_user hamsysmon" "$BUILD_SRC"; then
    fail_link "link 2 (build_user.sh): hamsysmon is not built"
fi
if ! grep -q "hamui_set_protocol_v2" "$SYSMON_SRC"; then
    fail_link "link 2 (hamsysmon.ad): does NOT call hamui_set_protocol_v2"
fi
if ! grep -q '"/dev/wsys/sysmon"' "$SYSMON_SRC"; then
    fail_link "link 2 (hamsysmon.ad): does NOT read /dev/wsys/sysmon snapshot"
fi
if ! grep -q "hamui_v2_commit_rect" "$SYSMON_SRC"; then
    fail_link "link 2 (hamsysmon.ad): does NOT call hamui_v2_commit_rect"
fi

# --- Link 3: kernel exposes /dev/wsys/sysmon + show leaves --------
for sym in "DEV_WSYS_SYSMON\b" "DEV_WSYS_SYSMON_SHOW"; do
    if ! grep -qE "${sym}" "$NAMEC_SRC"; then
        fail_link "link 3 (namec.ad): DEV constant ${sym} is missing"
    fi
done
for fn in devwsys_sysmon_read devwsys_sysmon_show_read devwsys_sysmon_show_write; do
    if ! grep -qE "def[[:space:]]+${fn}[[:space:]]*\(" "$KERN_SRC"; then
        fail_link "link 3 (devwsys.ad): ${fn}() definition is missing"
    fi
    if ! grep -q "${fn}" "$NAMEC_SRC"; then
        fail_link "link 3 (namec.ad): ${fn} is not wired into the dispatcher"
    fi
done
if ! grep -q '"sysmon/show"' "$NAMEC_SRC"; then
    fail_link "link 3 (namec.ad): sysmon/show path is not resolved"
fi
if ! grep -q '"sysmon"' "$NAMEC_SRC"; then
    fail_link "link 3 (namec.ad): sysmon path is not resolved"
fi
if ! grep -E "_wsys_ctl_word_eq" "$KERN_SRC" | grep -q '"sysmon"'; then
    fail_link "link 3 (devwsys.ad): /dev/wsys/ctl 'sysmon' verb is missing"
fi

# --- Link 4: compositor publishes, spawns, and pokes ---------------
for fn in sysmon_publish_snapshot sysmon_spawn sysmon_poke_show sysmon_publish_if_changed; do
    if ! grep -qE "def[[:space:]]+${fn}[[:space:]]*\(" "$HAMUID_SRC"; then
        fail_link "link 4 (hamUId.ad): ${fn}() definition is missing"
    fi
done
if ! grep -q "sysmon_spawn(" "$HAMUID_SRC"; then
    fail_link "link 4 (hamUId.ad): sysmon_spawn is never called"
fi
if ! grep -q '"/bin/hamsysmon"' "$HAMUID_SRC"; then
    fail_link "link 4 (hamUId.ad): the compositor does NOT spawn /bin/hamsysmon"
fi
post_present_body=$(awk '
    /^def[[:space:]]+post_present_overlays[[:space:]]*\(/ { inside=1; print; next }
    /^def[[:space:]]/ { if (inside) { inside=0 } }
    inside { print }
' "$HAMUID_SRC")
if ! grep -q "sysmon_publish_if_changed()" <<< "$post_present_body"; then
    fail_link "link 4 (hamUId.ad): post_present_overlays does NOT call sysmon_publish_if_changed"
fi

# --- Link 5: publish path uses the kernel files --------------------
pub_body=$(awk '
    /^def[[:space:]]+sysmon_publish_snapshot[[:space:]]*\(/ { inside=1; print; next }
    /^def[[:space:]]/ { if (inside) { inside=0 } }
    inside { print }
' "$HAMUID_SRC")
if ! grep -q '"/dev/wsys/ctl"' <<< "$pub_body"; then
    fail_link "link 5 (hamUId.ad): sysmon_publish_snapshot does NOT write /dev/wsys/ctl"
fi
if ! grep -q '"sysmon "' <<< "$pub_body"; then
    fail_link "link 5 (hamUId.ad): sysmon_publish_snapshot does NOT emit the 'sysmon' verb"
fi
poke_body=$(awk '
    /^def[[:space:]]+sysmon_poke_show[[:space:]]*\(/ { inside=1; print; next }
    /^def[[:space:]]/ { if (inside) { inside=0 } }
    inside { print }
' "$HAMUID_SRC")
if ! grep -q '"/dev/wsys/sysmon/show"' <<< "$poke_body"; then
    fail_link "link 5 (hamUId.ad): sysmon_poke_show does NOT write /dev/wsys/sysmon/show"
fi

if [ "$fail" -ne 0 ]; then
    echo "FAIL: sysmon v2 extraction BROKEN (see link(s) above)" >&2
    exit 1
fi

echo "PASS: sysmon v2 extraction intact"
exit 0
