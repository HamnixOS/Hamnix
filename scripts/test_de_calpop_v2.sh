#!/usr/bin/env bash
# scripts/test_de_calpop_v2.sh — DE pivot wave 4 structural guard:
# the panel clock's drop-down monthly calendar popup is no longer
# drawn by the daemon_pixel monolith. It now lives in /bin/hamcalpop,
# a separate-process v2 client that reads its model from
# /dev/wsys/calpop and is woken by writes to /dev/wsys/calpop/show.
# The compositor (user/hamUId.ad) publishes the model on every
# cal_toggle / clock_refresh and pokes the show serial.
#
# Distinct from /bin/hamclock — that is the standalone clock app.
#
# Pass marker:  PASS: calpop v2 extraction intact
# Fail marker:  FAIL: <which link broke>

set -euo pipefail

PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

KERN_SRC="sys/src/9/port/devwsys.ad"
NAMEC_SRC="sys/src/9/port/namec.ad"
HAMUID_SRC="user/hamUId.ad"
CALPOP_SRC="user/hamcalpop.ad"
BUILD_SRC="scripts/build_user.sh"

fail=0
fail_link() {
    echo "FAIL: $1" >&2
    fail=1
}

for f in "$KERN_SRC" "$NAMEC_SRC" "$HAMUID_SRC" "$CALPOP_SRC" "$BUILD_SRC"; do
    if [ ! -f "$f" ]; then
        echo "FAIL: $f missing" >&2
        exit 1
    fi
done

# --- Link 1: calendar-pixel paths are GONE from daemon_pixel --------
# The legacy popup render fanned out a ~85-line "clock calendar
# popup (monthly grid)" block keyed on CAL_OPEN inside daemon_pixel.
# If any of its render bindings (CAL_HEAD_R/CAL_TXT_R/cal_day_at/
# cal_dow_initial/cal_month_name) still appear inside daemon_pixel,
# the renderer regressed back to the monolith.
daemon_pixel_body=$(awk '
    /^def[[:space:]]+daemon_pixel[[:space:]]*\(/ { inside=1; print; next }
    /^def[[:space:]]/ { if (inside) { inside=0 } }
    inside { print }
' "$HAMUID_SRC")
if [ -z "$daemon_pixel_body" ]; then
    fail_link "link 1 (hamUId.ad): daemon_pixel() not found - is it renamed?"
fi
for sym in "CAL_HEAD_R" "CAL_TXT_R" "CAL_CELL_W" "cal_day_at" "cal_dow_initial" "cal_month_name"; do
    if grep -qE "$sym" <<< "$daemon_pixel_body"; then
        fail_link "link 1 (hamUId.ad): daemon_pixel still references '$sym' - calendar popup rendering did not extract cleanly"
    fi
done
# A breadcrumb comment marking the extraction must remain so a future
# refactor doesn't silently re-inline.
if ! grep -q "clock calendar popup rendering EXTRACTED" <<< "$daemon_pixel_body"; then
    fail_link "link 1 (hamUId.ad): the 'clock calendar popup rendering EXTRACTED' breadcrumb is gone - regression marker missing"
fi

# --- Link 2: hamcalpop binary is registered + sources ---------------
if ! grep -q "build_adder_user hamcalpop" "$BUILD_SRC"; then
    fail_link "link 2 (build_user.sh): hamcalpop is not built - the binary won't ship in the initramfs"
fi
# hamcalpop must opt into v2 + read the snapshot.
if ! grep -q "hamui_set_protocol_v2" "$CALPOP_SRC"; then
    fail_link "link 2 (hamcalpop.ad): does NOT call hamui_set_protocol_v2 - it isn't a v2 client"
fi
if ! grep -q '"/dev/wsys/calpop"' "$CALPOP_SRC"; then
    fail_link "link 2 (hamcalpop.ad): does NOT read /dev/wsys/calpop snapshot - the model source is missing"
fi
# It must commit dirty rects via the v2 wire protocol.
if ! grep -q "hamui_v2_commit_rect" "$CALPOP_SRC"; then
    fail_link "link 2 (hamcalpop.ad): does NOT call hamui_v2_commit_rect - no pixels reach the kernel backbuffer"
fi

# --- Link 3: kernel exposes /dev/wsys/calpop + show leaf ------------
for sym in "DEV_WSYS_CALPOP\b" "DEV_WSYS_CALPOP_SHOW"; do
    if ! grep -qE "${sym}" "$NAMEC_SRC"; then
        fail_link "link 3 (namec.ad): DEV constant ${sym} is missing"
    fi
done
for fn in devwsys_calpop_read devwsys_calpop_show_read devwsys_calpop_show_write; do
    if ! grep -qE "def[[:space:]]+${fn}[[:space:]]*\(" "$KERN_SRC"; then
        fail_link "link 3 (devwsys.ad): ${fn}() definition is missing"
    fi
    if ! grep -q "${fn}" "$NAMEC_SRC"; then
        fail_link "link 3 (namec.ad): ${fn} is not wired into the dispatcher"
    fi
done
if ! grep -q '"calpop/show"' "$NAMEC_SRC"; then
    fail_link "link 3 (namec.ad): calpop/show path is not resolved"
fi
if ! grep -q '"calpop"' "$NAMEC_SRC"; then
    fail_link "link 3 (namec.ad): calpop path is not resolved"
fi
# The /dev/wsys/ctl `calpop` verb is how hamUId publishes the model.
if ! grep -E "_wsys_ctl_word_eq" "$KERN_SRC" | grep -q '"calpop"'; then
    fail_link "link 3 (devwsys.ad): /dev/wsys/ctl 'calpop' verb is missing - the compositor can't publish the model"
fi

# --- Link 4: compositor publishes, spawns, and pokes ----------------
for fn in calpop_publish_snapshot calpop_spawn calpop_poke_show; do
    if ! grep -qE "def[[:space:]]+${fn}[[:space:]]*\(" "$HAMUID_SRC"; then
        fail_link "link 4 (hamUId.ad): ${fn}() definition is missing"
    fi
done
# publish + poke must run on every cal_toggle (so the client sees the
# new open/closed state each clock-applet click).
toggle_body=$(awk '
    /^def[[:space:]]+cal_toggle[[:space:]]*\(/ { inside=1; print; next }
    /^def[[:space:]]/ { if (inside) { inside=0 } }
    inside { print }
' "$HAMUID_SRC")
if ! grep -q "calpop_publish_snapshot()" <<< "$toggle_body"; then
    fail_link "link 4 (hamUId.ad): cal_toggle() does NOT call calpop_publish_snapshot - clicks won't update the overlay model"
fi
if ! grep -q "calpop_poke_show()" <<< "$toggle_body"; then
    fail_link "link 4 (hamUId.ad): cal_toggle() does NOT call calpop_poke_show - the client never gets woken on a toggle"
fi
# spawn must be called from daemon startup.
if ! grep -q "calpop_spawn(" "$HAMUID_SRC"; then
    fail_link "link 4 (hamUId.ad): calpop_spawn is never called - the client is never launched"
fi
# It must spawn the SEPARATE-PROCESS hamcalpop binary, not draw inline.
if ! grep -q '"/bin/hamcalpop"' "$HAMUID_SRC"; then
    fail_link "link 4 (hamUId.ad): the compositor does NOT spawn /bin/hamcalpop - extraction is just a comment, not a behaviour change"
fi

# --- Link 5: publish path uses the kernel verb ----------------------
pub_body=$(awk '
    /^def[[:space:]]+calpop_publish_snapshot[[:space:]]*\(/ { inside=1; print; next }
    /^def[[:space:]]/ { if (inside) { inside=0 } }
    inside { print }
' "$HAMUID_SRC")
if ! grep -q '"/dev/wsys/ctl"' <<< "$pub_body"; then
    fail_link "link 5 (hamUId.ad): calpop_publish_snapshot does NOT write /dev/wsys/ctl - the model never reaches the kernel"
fi
if ! grep -q '"calpop "' <<< "$pub_body"; then
    fail_link "link 5 (hamUId.ad): calpop_publish_snapshot does NOT emit the 'calpop' verb - the kernel won't accept the payload"
fi
poke_body=$(awk '
    /^def[[:space:]]+calpop_poke_show[[:space:]]*\(/ { inside=1; print; next }
    /^def[[:space:]]/ { if (inside) { inside=0 } }
    inside { print }
' "$HAMUID_SRC")
if ! grep -q '"/dev/wsys/calpop/show"' <<< "$poke_body"; then
    fail_link "link 5 (hamUId.ad): calpop_poke_show does NOT write /dev/wsys/calpop/show - the show-serial never bumps"
fi

if [ "$fail" -ne 0 ]; then
    echo "FAIL: calpop v2 extraction BROKEN (see link(s) above)" >&2
    exit 1
fi

echo "PASS: calpop v2 extraction intact"
exit 0
