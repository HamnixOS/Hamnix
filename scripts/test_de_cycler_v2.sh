#!/usr/bin/env bash
# scripts/test_de_cycler_v2.sh — DE pivot wave 3 structural guard:
# the MATE-style Alt-Tab window switcher overlay is no longer drawn by
# the daemon_pixel monolith. It now lives in /bin/hamcycler, a separate-
# process v2 client that reads its model from /dev/wsys/cycler and is
# woken by writes to /dev/wsys/cycler/show. The compositor
# (user/hamUId.ad) publishes the model on every cycle step / commit and
# pokes the show serial.
#
# Pass marker:  PASS: cycler v2 extraction intact
# Fail marker:  FAIL: <which link broke>

set -euo pipefail

PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

KERN_SRC="sys/src/9/port/devwsys.ad"
NAMEC_SRC="sys/src/9/port/namec.ad"
HAMUID_SRC="user/hamUId.ad"
CYCLER_SRC="user/hamcycler.ad"
BUILD_SRC="scripts/build_user.sh"

fail=0
fail_link() {
    echo "FAIL: $1" >&2
    fail=1
}

for f in "$KERN_SRC" "$NAMEC_SRC" "$HAMUID_SRC" "$CYCLER_SRC" "$BUILD_SRC"; do
    if [ ! -f "$f" ]; then
        echo "FAIL: $f missing" >&2
        exit 1
    fi
done

# --- Link 1: cycler-pixel paths are GONE from daemon_pixel ----------
# The legacy switcher render fanned out a ~55-line "alt-tab switcher
# popup (centred window list)" block keyed on CYCLE_OPEN inside
# daemon_pixel. If any of its render bindings (CYC_W/CYC_PAD/CYC_R/
# cycle_slot_for_pos) still appear inside daemon_pixel, the renderer
# regressed back to the monolith.
daemon_pixel_body=$(awk '
    /^def[[:space:]]+daemon_pixel[[:space:]]*\(/ { inside=1; print; next }
    /^def[[:space:]]/ { if (inside) { inside=0 } }
    inside { print }
' "$HAMUID_SRC")
if [ -z "$daemon_pixel_body" ]; then
    fail_link "link 1 (hamUId.ad): daemon_pixel() not found - is it renamed?"
fi
for sym in "CYC_W" "CYC_PAD" "CYC_R\b" "CYC_SEL_R" "CYC_TXT_R" "cycle_slot_for_pos" "cycle_visible_count"; do
    if grep -qE "$sym" <<< "$daemon_pixel_body"; then
        fail_link "link 1 (hamUId.ad): daemon_pixel still references '$sym' - cycler rendering did not extract cleanly"
    fi
done
# A breadcrumb comment marking the extraction must remain so a future
# refactor doesn't silently re-inline.
if ! grep -q "Alt-Tab cycler rendering EXTRACTED" <<< "$daemon_pixel_body"; then
    fail_link "link 1 (hamUId.ad): the 'Alt-Tab cycler rendering EXTRACTED' breadcrumb is gone - regression marker missing"
fi

# --- Link 2: hamcycler binary is registered + sources ---------------
if ! grep -q "build_adder_user hamcycler" "$BUILD_SRC"; then
    fail_link "link 2 (build_user.sh): hamcycler is not built - the binary won't ship in the initramfs"
fi
# hamcycler must opt into v2 + read the snapshot.
if ! grep -q "hamui_set_protocol_v2" "$CYCLER_SRC"; then
    fail_link "link 2 (hamcycler.ad): does NOT call hamui_set_protocol_v2 - it isn't a v2 client"
fi
if ! grep -q '"/dev/wsys/cycler"' "$CYCLER_SRC"; then
    fail_link "link 2 (hamcycler.ad): does NOT read /dev/wsys/cycler snapshot - the model source is missing"
fi
# It must commit dirty rects via the v2 wire protocol.
if ! grep -q "hamui_v2_commit_rect" "$CYCLER_SRC"; then
    fail_link "link 2 (hamcycler.ad): does NOT call hamui_v2_commit_rect - no pixels reach the kernel backbuffer"
fi

# --- Link 3: kernel exposes /dev/wsys/cycler + show leaf ------------
for sym in "DEV_WSYS_CYCLER\b" "DEV_WSYS_CYCLER_SHOW"; do
    if ! grep -qE "${sym}" "$NAMEC_SRC"; then
        fail_link "link 3 (namec.ad): DEV constant ${sym} is missing"
    fi
done
for fn in devwsys_cycler_read devwsys_cycler_show_read devwsys_cycler_show_write; do
    if ! grep -qE "def[[:space:]]+${fn}[[:space:]]*\(" "$KERN_SRC"; then
        fail_link "link 3 (devwsys.ad): ${fn}() definition is missing"
    fi
    if ! grep -q "${fn}" "$NAMEC_SRC"; then
        fail_link "link 3 (namec.ad): ${fn} is not wired into the dispatcher"
    fi
done
if ! grep -q '"cycler/show"' "$NAMEC_SRC"; then
    fail_link "link 3 (namec.ad): cycler/show path is not resolved"
fi
if ! grep -q '"cycler"' "$NAMEC_SRC"; then
    fail_link "link 3 (namec.ad): cycler path is not resolved"
fi
# The /dev/wsys/ctl `cycler` verb is how hamUId publishes the model.
if ! grep -E "_wsys_ctl_word_eq" "$KERN_SRC" | grep -q '"cycler"'; then
    fail_link "link 3 (devwsys.ad): /dev/wsys/ctl 'cycler' verb is missing - the compositor can't publish the model"
fi

# --- Link 4: compositor publishes, spawns, and pokes ----------------
for fn in cycler_publish_snapshot cycler_spawn cycler_poke_show; do
    if ! grep -qE "def[[:space:]]+${fn}[[:space:]]*\(" "$HAMUID_SRC"; then
        fail_link "link 4 (hamUId.ad): ${fn}() definition is missing"
    fi
done
# publish + poke must run on every cycle_step (so the client sees the
# new selection each F5/F6 press).
step_body=$(awk '
    /^def[[:space:]]+cycle_step[[:space:]]*\(/ { inside=1; print; next }
    /^def[[:space:]]/ { if (inside) { inside=0 } }
    inside { print }
' "$HAMUID_SRC")
if ! grep -q "cycler_publish_snapshot()" <<< "$step_body"; then
    fail_link "link 4 (hamUId.ad): cycle_step() does NOT call cycler_publish_snapshot - F5/F6 won't update the overlay model"
fi
if ! grep -q "cycler_poke_show()" <<< "$step_body"; then
    fail_link "link 4 (hamUId.ad): cycle_step() does NOT call cycler_poke_show - the client never gets woken on a step"
fi
# Also on commit (so the overlay clears).
commit_body=$(awk '
    /^def[[:space:]]+cycle_commit[[:space:]]*\(/ { inside=1; print; next }
    /^def[[:space:]]/ { if (inside) { inside=0 } }
    inside { print }
' "$HAMUID_SRC")
if ! grep -q "cycler_publish_snapshot()" <<< "$commit_body"; then
    fail_link "link 4 (hamUId.ad): cycle_commit() does NOT call cycler_publish_snapshot - the overlay never clears"
fi
# spawn must be called from daemon startup.
if ! grep -q "cycler_spawn(" "$HAMUID_SRC"; then
    fail_link "link 4 (hamUId.ad): cycler_spawn is never called - the client is never launched"
fi
# It must spawn the SEPARATE-PROCESS hamcycler binary, not draw inline.
if ! grep -q '"/bin/hamcycler"' "$HAMUID_SRC"; then
    fail_link "link 4 (hamUId.ad): the compositor does NOT spawn /bin/hamcycler - extraction is just a comment, not a behaviour change"
fi

# --- Link 5: publish path uses the kernel verb ----------------------
pub_body=$(awk '
    /^def[[:space:]]+cycler_publish_snapshot[[:space:]]*\(/ { inside=1; print; next }
    /^def[[:space:]]/ { if (inside) { inside=0 } }
    inside { print }
' "$HAMUID_SRC")
if ! grep -q '"/dev/wsys/ctl"' <<< "$pub_body"; then
    fail_link "link 5 (hamUId.ad): cycler_publish_snapshot does NOT write /dev/wsys/ctl - the model never reaches the kernel"
fi
if ! grep -q '"cycler "' <<< "$pub_body"; then
    fail_link "link 5 (hamUId.ad): cycler_publish_snapshot does NOT emit the 'cycler' verb - the kernel won't accept the payload"
fi
poke_body=$(awk '
    /^def[[:space:]]+cycler_poke_show[[:space:]]*\(/ { inside=1; print; next }
    /^def[[:space:]]/ { if (inside) { inside=0 } }
    inside { print }
' "$HAMUID_SRC")
if ! grep -q '"/dev/wsys/cycler/show"' <<< "$poke_body"; then
    fail_link "link 5 (hamUId.ad): cycler_poke_show does NOT write /dev/wsys/cycler/show - the show-serial never bumps"
fi

if [ "$fail" -ne 0 ]; then
    echo "FAIL: cycler v2 extraction BROKEN (see link(s) above)" >&2
    exit 1
fi

echo "PASS: cycler v2 extraction intact"
exit 0
