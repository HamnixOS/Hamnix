#!/usr/bin/env bash
# scripts/test_de_run_v2.sh — DE pivot wave 4 structural guard:
# the MATE-style "Run Application..." (Alt-F2) modal text-entry dialog
# is no longer drawn by the daemon_pixel monolith. It now lives in
# /bin/hamrun, a separate-process v2 client that reads its model from
# /dev/wsys/run and is woken by writes to /dev/wsys/run/show. The
# compositor (user/hamUId.ad) publishes the model on every dialog
# mutation, pokes the show serial, and drains /dev/wsys/run/launch
# whenever Enter enqueues a program path.
#
# Pass marker:  PASS: run v2 extraction intact
# Fail marker:  FAIL: <which link broke>

set -euo pipefail

PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

KERN_SRC="sys/src/9/port/devwsys.ad"
NAMEC_SRC="sys/src/9/port/namec.ad"
HAMUID_SRC="user/hamUId.ad"
RUN_SRC="user/hamrun.ad"
BUILD_SRC="scripts/build_user.sh"

fail=0
fail_link() {
    echo "FAIL: $1" >&2
    fail=1
}

for f in "$KERN_SRC" "$NAMEC_SRC" "$HAMUID_SRC" "$RUN_SRC" "$BUILD_SRC"; do
    if [ ! -f "$f" ]; then
        echo "FAIL: $f missing" >&2
        exit 1
    fi
done

# --- Link 1: run-pixel paths are GONE from daemon_pixel -------------
# The legacy modal dialog fanned out a ~55-line "Run Application" cascade
# inside daemon_pixel, keyed on RUN_OPEN. If any of its render bindings
# (RUN_W/RUN_PAD/RUN_FIELD_H/run_buf rendering) still appear inside
# daemon_pixel, the renderer regressed back to the monolith.
daemon_pixel_body=$(awk '
    /^def[[:space:]]+daemon_pixel[[:space:]]*\(/ { inside=1; print; next }
    /^def[[:space:]]/ { if (inside) { inside=0 } }
    inside { print }
' "$HAMUID_SRC")
if [ -z "$daemon_pixel_body" ]; then
    fail_link "link 1 (hamUId.ad): daemon_pixel() not found - is it renamed?"
fi
for sym in "RUN_W\b" "RUN_PAD\b" "RUN_FIELD_H" "run_buf" "RUN_LEN"; do
    if grep -qE "$sym" <<< "$daemon_pixel_body"; then
        fail_link "link 1 (hamUId.ad): daemon_pixel still references '$sym' - run-dialog rendering did not extract cleanly"
    fi
done
# A breadcrumb comment marking the extraction must remain so a future
# refactor doesn't silently re-inline.
if ! grep -q "Run dialog .*EXTRACTED" <<< "$daemon_pixel_body"; then
    fail_link "link 1 (hamUId.ad): the 'Run dialog ... EXTRACTED' breadcrumb is gone - regression marker missing"
fi

# --- Link 2: hamrun binary is registered + sources ------------------
if ! grep -q "build_adder_user hamrun" "$BUILD_SRC"; then
    fail_link "link 2 (build_user.sh): hamrun is not built - the binary won't ship in the initramfs"
fi
# hamrun must opt into v2 + read the snapshot.
if ! grep -q "hamui_set_protocol_v2" "$RUN_SRC"; then
    fail_link "link 2 (hamrun.ad): does NOT call hamui_set_protocol_v2 - it isn't a v2 client"
fi
if ! grep -q '"/dev/wsys/run"' "$RUN_SRC"; then
    fail_link "link 2 (hamrun.ad): does NOT read /dev/wsys/run snapshot - the model source is missing"
fi
# It must commit dirty rects via the v2 wire protocol.
if ! grep -q "hamui_v2_commit_rect" "$RUN_SRC"; then
    fail_link "link 2 (hamrun.ad): does NOT call hamui_v2_commit_rect - no pixels reach the kernel backbuffer"
fi

# --- Link 3: kernel exposes /dev/wsys/run + show + launch leaves ----
for sym in "DEV_WSYS_RUN\b" "DEV_WSYS_RUN_SHOW" "DEV_WSYS_RUN_LAUNCH"; do
    if ! grep -qE "${sym}" "$NAMEC_SRC"; then
        fail_link "link 3 (namec.ad): DEV constant ${sym} is missing"
    fi
done
for fn in devwsys_run_read devwsys_run_show_read devwsys_run_show_write \
          devwsys_run_launch_read devwsys_run_launch_write; do
    if ! grep -qE "def[[:space:]]+${fn}[[:space:]]*\(" "$KERN_SRC"; then
        fail_link "link 3 (devwsys.ad): ${fn}() definition is missing"
    fi
    if ! grep -q "${fn}" "$NAMEC_SRC"; then
        fail_link "link 3 (namec.ad): ${fn} is not wired into the dispatcher"
    fi
done
if ! grep -q '"run/show"' "$NAMEC_SRC"; then
    fail_link "link 3 (namec.ad): run/show path is not resolved"
fi
if ! grep -q '"run/launch"' "$NAMEC_SRC"; then
    fail_link "link 3 (namec.ad): run/launch path is not resolved"
fi
if ! grep -q '"run"' "$NAMEC_SRC"; then
    fail_link "link 3 (namec.ad): run path is not resolved"
fi
# The /dev/wsys/ctl `run` verb is how hamUId publishes the model.
if ! grep -E "_wsys_ctl_word_eq" "$KERN_SRC" | grep -q '"run"'; then
    fail_link "link 3 (devwsys.ad): /dev/wsys/ctl 'run' verb is missing - the compositor can't publish the model"
fi

# --- Link 4: compositor publishes, spawns, pokes, and drains --------
for fn in run_publish_snapshot run_spawn run_poke_show run_drain_launch; do
    if ! grep -qE "def[[:space:]]+${fn}[[:space:]]*\(" "$HAMUID_SRC"; then
        fail_link "link 4 (hamUId.ad): ${fn}() definition is missing"
    fi
done
# publish + poke must fire from every dialog state mutation.
for hook in run_open run_cancel run_push run_backspace; do
    body=$(awk -v fn="$hook" '
        $0 ~ "^def[[:space:]]+"fn"[[:space:]]*\\(" { inside=1; print; next }
        /^def[[:space:]]/ { if (inside) { inside=0 } }
        inside { print }
    ' "$HAMUID_SRC")
    if [ -z "$body" ]; then
        fail_link "link 4 (hamUId.ad): ${hook}() not found"
        continue
    fi
    if ! grep -q "run_publish_snapshot()" <<< "$body"; then
        fail_link "link 4 (hamUId.ad): ${hook}() does NOT call run_publish_snapshot - hamrun won't see the state change"
    fi
    if ! grep -q "run_poke_show()" <<< "$body"; then
        fail_link "link 4 (hamUId.ad): ${hook}() does NOT call run_poke_show - the client never gets woken"
    fi
done
# spawn must be called from daemon startup.
if ! grep -q "run_spawn(" "$HAMUID_SRC"; then
    fail_link "link 4 (hamUId.ad): run_spawn is never called - the client is never launched"
fi
# It must spawn the SEPARATE-PROCESS hamrun binary, not draw inline.
if ! grep -q '"/bin/hamrun"' "$HAMUID_SRC"; then
    fail_link "link 4 (hamUId.ad): the compositor does NOT spawn /bin/hamrun - extraction is just a comment, not a behaviour change"
fi
# drain_launch must run in the daemon main loop.
if ! grep -q "run_drain_launch(" "$HAMUID_SRC"; then
    fail_link "link 4 (hamUId.ad): run_drain_launch is never called - the launch slot is unread"
fi

# --- Link 5: publish + drain paths use the kernel files -------------
pub_body=$(awk '
    /^def[[:space:]]+run_publish_snapshot[[:space:]]*\(/ { inside=1; print; next }
    /^def[[:space:]]/ { if (inside) { inside=0 } }
    inside { print }
' "$HAMUID_SRC")
if ! grep -q '"/dev/wsys/ctl"' <<< "$pub_body"; then
    fail_link "link 5 (hamUId.ad): run_publish_snapshot does NOT write /dev/wsys/ctl - the model never reaches the kernel"
fi
if ! grep -q '"run "' <<< "$pub_body"; then
    fail_link "link 5 (hamUId.ad): run_publish_snapshot does NOT emit the 'run' verb - the kernel won't accept the payload"
fi
poke_body=$(awk '
    /^def[[:space:]]+run_poke_show[[:space:]]*\(/ { inside=1; print; next }
    /^def[[:space:]]/ { if (inside) { inside=0 } }
    inside { print }
' "$HAMUID_SRC")
if ! grep -q '"/dev/wsys/run/show"' <<< "$poke_body"; then
    fail_link "link 5 (hamUId.ad): run_poke_show does NOT write /dev/wsys/run/show - the show-serial never bumps"
fi
drain_body=$(awk '
    /^def[[:space:]]+run_drain_launch[[:space:]]*\(/ { inside=1; print; next }
    /^def[[:space:]]/ { if (inside) { inside=0 } }
    inside { print }
' "$HAMUID_SRC")
if ! grep -q '"/dev/wsys/run/launch"' <<< "$drain_body"; then
    fail_link "link 5 (hamUId.ad): run_drain_launch does NOT read /dev/wsys/run/launch - the watcher is wired to nothing"
fi
if ! grep -q "daemon_spawn_window_prog" <<< "$drain_body"; then
    fail_link "link 5 (hamUId.ad): run_drain_launch does NOT call daemon_spawn_window_prog - a launch never becomes a window"
fi
# run_launch must enqueue via /dev/wsys/run/launch (Plan-9 IPC, not an
# in-compositor function call).
launch_body=$(awk '
    /^def[[:space:]]+run_launch[[:space:]]*\(/ { inside=1; print; next }
    /^def[[:space:]]/ { if (inside) { inside=0 } }
    inside { print }
' "$HAMUID_SRC")
if ! grep -q '"/dev/wsys/run/launch"' <<< "$launch_body"; then
    fail_link "link 5 (hamUId.ad): run_launch does NOT write /dev/wsys/run/launch - the IPC half of the extraction is missing"
fi

if [ "$fail" -ne 0 ]; then
    echo "FAIL: run v2 extraction BROKEN (see link(s) above)" >&2
    exit 1
fi

echo "PASS: run v2 extraction intact"
exit 0
