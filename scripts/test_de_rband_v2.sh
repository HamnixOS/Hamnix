#!/usr/bin/env bash
# scripts/test_de_rband_v2.sh — DE pivot wave 7 structural guard:
# the rubber-band drag-to-create overlay (the 1-pixel dashed outline
# that follows the cursor during a drag-out gesture) is no longer drawn
# by the daemon_pixel monolith / post_present_overlays. It now lives in
# /bin/hamrband, a separate-process v2 client that reads its model from
# /dev/wsys/rband and is woken by writes to /dev/wsys/rband/set. The
# compositor (user/hamUId.ad) republishes the model every frame the
# drag rect changes and pokes the set serial.
#
# Pass marker:  PASS: rband v2 extraction intact
# Fail marker:  FAIL: <which link broke>

set -euo pipefail

PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

KERN_SRC="sys/src/9/port/devwsys.ad"
NAMEC_SRC="sys/src/9/port/namec.ad"
HAMUID_SRC="user/hamUId.ad"
RBAND_SRC="user/hamrband.ad"
BUILD_SRC="scripts/build_user.sh"

fail=0
fail_link() {
    echo "FAIL: $1" >&2
    fail=1
}

for f in "$KERN_SRC" "$NAMEC_SRC" "$HAMUID_SRC" "$RBAND_SRC" "$BUILD_SRC"; do
    if [ ! -f "$f" ]; then
        echo "FAIL: $f missing" >&2
        exit 1
    fi
done

# --- Link 1: rband paint is GONE from post_present_overlays ---------
# The legacy overlay called scene_blit_rect_outline(...,255,255,0) from
# inside post_present_overlays gated on DRAG_ACTIVE != 0. Both that
# call and the body of the gate must be gone from post_present_overlays.
post_overlays_body=$(awk '
    /^def[[:space:]]+post_present_overlays[[:space:]]*\(/ { inside=1; print; next }
    /^def[[:space:]]/ { if (inside) { inside=0 } }
    inside { print }
' "$HAMUID_SRC")
if [ -z "$post_overlays_body" ]; then
    fail_link "link 1 (hamUId.ad): post_present_overlays() not found - is it renamed?"
fi
if grep -q "scene_blit_rect_outline" <<< "$post_overlays_body"; then
    fail_link "link 1 (hamUId.ad): post_present_overlays still calls scene_blit_rect_outline - rubber-band did not extract cleanly"
fi
if grep -q "DRAG_ACTIVE" <<< "$post_overlays_body"; then
    fail_link "link 1 (hamUId.ad): post_present_overlays still references DRAG_ACTIVE for an inline paint - the gate did not move out"
fi
# A breadcrumb comment marking the extraction must remain so a future
# refactor doesn't silently re-inline.
if ! grep -q "RUBBER-BAND outline rendering EXTRACTED" <<< "$post_overlays_body"; then
    fail_link "link 1 (hamUId.ad): the 'RUBBER-BAND outline rendering EXTRACTED' breadcrumb is gone - regression marker missing"
fi

# --- Link 2: hamrband binary is registered + sources ----------------
if ! grep -q "build_adder_user hamrband" "$BUILD_SRC"; then
    fail_link "link 2 (build_user.sh): hamrband is not built - the binary won't ship in the initramfs"
fi
# hamrband must opt into v2 + read the snapshot.
if ! grep -q "hamui_set_protocol_v2" "$RBAND_SRC"; then
    fail_link "link 2 (hamrband.ad): does NOT call hamui_set_protocol_v2 - it isn't a v2 client"
fi
if ! grep -q '"/dev/wsys/rband"' "$RBAND_SRC"; then
    fail_link "link 2 (hamrband.ad): does NOT read /dev/wsys/rband snapshot - the model source is missing"
fi
# It must commit dirty rects via the v2 wire protocol.
if ! grep -q "hamui_v2_commit_rect" "$RBAND_SRC"; then
    fail_link "link 2 (hamrband.ad): does NOT call hamui_v2_commit_rect - no pixels reach the kernel backbuffer"
fi

# --- Link 3: kernel exposes /dev/wsys/rband + rband/set leaves ------
for sym in "DEV_WSYS_RBAND\b" "DEV_WSYS_RBAND_SET"; do
    if ! grep -qE "${sym}" "$NAMEC_SRC"; then
        fail_link "link 3 (namec.ad): DEV constant ${sym} is missing"
    fi
done
for fn in devwsys_rband_read devwsys_rband_set_read devwsys_rband_set_write; do
    if ! grep -qE "def[[:space:]]+${fn}[[:space:]]*\(" "$KERN_SRC"; then
        fail_link "link 3 (devwsys.ad): ${fn}() definition is missing"
    fi
    if ! grep -q "${fn}" "$NAMEC_SRC"; then
        fail_link "link 3 (namec.ad): ${fn} is not wired into the dispatcher"
    fi
done
if ! grep -q '"rband/set"' "$NAMEC_SRC"; then
    fail_link "link 3 (namec.ad): rband/set path is not resolved"
fi
if ! grep -q '"rband"' "$NAMEC_SRC"; then
    fail_link "link 3 (namec.ad): rband path is not resolved"
fi
# The /dev/wsys/ctl `rband` verb is how hamUId publishes the model.
if ! grep -E "_wsys_ctl_word_eq" "$KERN_SRC" | grep -q '"rband"'; then
    fail_link "link 3 (devwsys.ad): /dev/wsys/ctl 'rband' verb is missing - the compositor can't publish the model"
fi

# --- Link 4: compositor publishes, spawns, and pokes ---------------
for fn in rband_publish_snapshot rband_spawn rband_poke_set rband_publish_if_changed; do
    if ! grep -qE "def[[:space:]]+${fn}[[:space:]]*\(" "$HAMUID_SRC"; then
        fail_link "link 4 (hamUId.ad): ${fn}() definition is missing"
    fi
done
# spawn must be called from daemon startup.
if ! grep -q "rband_spawn(" "$HAMUID_SRC"; then
    fail_link "link 4 (hamUId.ad): rband_spawn is never called - the client is never launched"
fi
# It must spawn the SEPARATE-PROCESS hamrband binary, not draw inline.
if ! grep -q '"/bin/hamrband"' "$HAMUID_SRC"; then
    fail_link "link 4 (hamUId.ad): the compositor does NOT spawn /bin/hamrband - extraction is just a comment, not a behaviour change"
fi
# publish_if_changed must run from post_present_overlays so the band
# tracks the cursor on every frame the drag rect changes.
if ! grep -q "rband_publish_if_changed()" <<< "$post_overlays_body"; then
    fail_link "link 4 (hamUId.ad): post_present_overlays does NOT call rband_publish_if_changed - the client never sees a moving band"
fi

# --- Link 5: publish + poke paths use the kernel files -------------
pub_body=$(awk '
    /^def[[:space:]]+rband_publish_snapshot[[:space:]]*\(/ { inside=1; print; next }
    /^def[[:space:]]/ { if (inside) { inside=0 } }
    inside { print }
' "$HAMUID_SRC")
if ! grep -q '"/dev/wsys/ctl"' <<< "$pub_body"; then
    fail_link "link 5 (hamUId.ad): rband_publish_snapshot does NOT write /dev/wsys/ctl - the model never reaches the kernel"
fi
if ! grep -q '"rband "' <<< "$pub_body"; then
    fail_link "link 5 (hamUId.ad): rband_publish_snapshot does NOT emit the 'rband' verb - the kernel won't accept the payload"
fi
poke_body=$(awk '
    /^def[[:space:]]+rband_poke_set[[:space:]]*\(/ { inside=1; print; next }
    /^def[[:space:]]/ { if (inside) { inside=0 } }
    inside { print }
' "$HAMUID_SRC")
if ! grep -q '"/dev/wsys/rband/set"' <<< "$poke_body"; then
    fail_link "link 5 (hamUId.ad): rband_poke_set does NOT write /dev/wsys/rband/set - the set-serial never bumps"
fi

# --- Link 6: rband_publish_if_changed diffs and only republishes on
# a real change (so still frames don't slam /dev/wsys/ctl).
diff_body=$(awk '
    /^def[[:space:]]+rband_publish_if_changed[[:space:]]*\(/ { inside=1; print; next }
    /^def[[:space:]]/ { if (inside) { inside=0 } }
    inside { print }
' "$HAMUID_SRC")
if ! grep -q "rband_publish_snapshot" <<< "$diff_body"; then
    fail_link "link 6 (hamUId.ad): rband_publish_if_changed does NOT call rband_publish_snapshot - the client never sees the model"
fi
if ! grep -q "rband_poke_set" <<< "$diff_body"; then
    fail_link "link 6 (hamUId.ad): rband_publish_if_changed does NOT call rband_poke_set - the client never wakes"
fi

if [ "$fail" -ne 0 ]; then
    echo "FAIL: rband v2 extraction BROKEN (see link(s) above)" >&2
    exit 1
fi

echo "PASS: rband v2 extraction intact"
exit 0
