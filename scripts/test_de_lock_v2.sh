#!/usr/bin/env bash
# scripts/test_de_lock_v2.sh — DE pivot wave 5 structural guard:
# the full-screen screen-lock overlay ("Screen Locked / Click to unlock")
# is no longer drawn by the daemon_pixel monolith. It now lives in
# /bin/hamlock, a separate-process v2 client that reads its model from
# /dev/wsys/lock and is woken by writes to /dev/wsys/lock/show. The
# compositor (user/hamUId.ad) publishes the model on every session_lock
# / session_unlock mutation, pokes the show serial, and drains
# /dev/wsys/lock/verify whenever a password attempt is enqueued.
#
# Pass marker:  PASS: lock v2 extraction intact
# Fail marker:  FAIL: <which link broke>

set -euo pipefail

PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

KERN_SRC="sys/src/9/port/devwsys.ad"
NAMEC_SRC="sys/src/9/port/namec.ad"
HAMUID_SRC="user/hamUId.ad"
LOCK_SRC="user/hamlock.ad"
BUILD_SRC="scripts/build_user.sh"

fail=0
fail_link() {
    echo "FAIL: $1" >&2
    fail=1
}

for f in "$KERN_SRC" "$NAMEC_SRC" "$HAMUID_SRC" "$LOCK_SRC" "$BUILD_SRC"; do
    if [ ! -f "$f" ]; then
        echo "FAIL: $f missing" >&2
        exit 1
    fi
done

# --- Link 1: lock-pixel paths are GONE from daemon_pixel ------------
# The legacy overlay rendered the "Screen Locked" + "Click to unlock"
# strings inline via str_ink, gated on `if LOCKED != 0:`. The literal
# strings + the LOCKED-keyed render gate must be gone from daemon_pixel.
daemon_pixel_body=$(awk '
    /^def[[:space:]]+daemon_pixel[[:space:]]*\(/ { inside=1; print; next }
    /^def[[:space:]]/ { if (inside) { inside=0 } }
    inside { print }
' "$HAMUID_SRC")
if [ -z "$daemon_pixel_body" ]; then
    fail_link "link 1 (hamUId.ad): daemon_pixel() not found - is it renamed?"
fi
for sym in '"Screen Locked"' '"Click to unlock"'; do
    if grep -qF "$sym" <<< "$daemon_pixel_body"; then
        fail_link "link 1 (hamUId.ad): daemon_pixel still references '$sym' - lock overlay rendering did not extract cleanly"
    fi
done
# A breadcrumb comment marking the extraction must remain so a future
# refactor doesn't silently re-inline.
if ! grep -q "LOCK overlay rendering EXTRACTED" <<< "$daemon_pixel_body"; then
    fail_link "link 1 (hamUId.ad): the 'LOCK overlay rendering EXTRACTED' breadcrumb is gone - regression marker missing"
fi

# --- Link 2: hamlock binary is registered + sources -----------------
if ! grep -q "build_adder_user hamlock" "$BUILD_SRC"; then
    fail_link "link 2 (build_user.sh): hamlock is not built - the binary won't ship in the initramfs"
fi
# hamlock must opt into v2 + read the snapshot.
if ! grep -q "hamui_set_protocol_v2" "$LOCK_SRC"; then
    fail_link "link 2 (hamlock.ad): does NOT call hamui_set_protocol_v2 - it isn't a v2 client"
fi
if ! grep -q '"/dev/wsys/lock"' "$LOCK_SRC"; then
    fail_link "link 2 (hamlock.ad): does NOT read /dev/wsys/lock snapshot - the model source is missing"
fi
# It must commit dirty rects via the v2 wire protocol.
if ! grep -q "hamui_v2_commit_rect" "$LOCK_SRC"; then
    fail_link "link 2 (hamlock.ad): does NOT call hamui_v2_commit_rect - no pixels reach the kernel backbuffer"
fi

# --- Link 3: kernel exposes /dev/wsys/lock + show + verify leaves ---
for sym in "DEV_WSYS_LOCK\b" "DEV_WSYS_LOCK_SHOW" "DEV_WSYS_LOCK_VERIFY"; do
    if ! grep -qE "${sym}" "$NAMEC_SRC"; then
        fail_link "link 3 (namec.ad): DEV constant ${sym} is missing"
    fi
done
for fn in devwsys_lock_read devwsys_lock_show_read devwsys_lock_show_write \
          devwsys_lock_verify_read devwsys_lock_verify_write; do
    if ! grep -qE "def[[:space:]]+${fn}[[:space:]]*\(" "$KERN_SRC"; then
        fail_link "link 3 (devwsys.ad): ${fn}() definition is missing"
    fi
    if ! grep -q "${fn}" "$NAMEC_SRC"; then
        fail_link "link 3 (namec.ad): ${fn} is not wired into the dispatcher"
    fi
done
if ! grep -q '"lock/show"' "$NAMEC_SRC"; then
    fail_link "link 3 (namec.ad): lock/show path is not resolved"
fi
if ! grep -q '"lock/verify"' "$NAMEC_SRC"; then
    fail_link "link 3 (namec.ad): lock/verify path is not resolved"
fi
if ! grep -q '"lock"' "$NAMEC_SRC"; then
    fail_link "link 3 (namec.ad): lock path is not resolved"
fi
# The /dev/wsys/ctl `lock` verb is how hamUId publishes the model.
if ! grep -E "_wsys_ctl_word_eq" "$KERN_SRC" | grep -q '"lock"'; then
    fail_link "link 3 (devwsys.ad): /dev/wsys/ctl 'lock' verb is missing - the compositor can't publish the model"
fi

# --- Link 4: compositor publishes, spawns, pokes, and drains --------
for fn in lock_publish_snapshot lock_spawn lock_poke_show lock_drain_verify; do
    if ! grep -qE "def[[:space:]]+${fn}[[:space:]]*\(" "$HAMUID_SRC"; then
        fail_link "link 4 (hamUId.ad): ${fn}() definition is missing"
    fi
done
# publish + poke must fire from session_lock + session_unlock (so the
# client sees the locked/unlocked transition each time).
for hook in session_lock session_unlock; do
    body=$(awk -v fn="$hook" '
        $0 ~ "^def[[:space:]]+"fn"[[:space:]]*\\(" { inside=1; print; next }
        /^def[[:space:]]/ { if (inside) { inside=0 } }
        inside { print }
    ' "$HAMUID_SRC")
    if [ -z "$body" ]; then
        fail_link "link 4 (hamUId.ad): ${hook}() not found"
        continue
    fi
    if ! grep -q "lock_publish_snapshot()" <<< "$body"; then
        fail_link "link 4 (hamUId.ad): ${hook}() does NOT call lock_publish_snapshot - hamlock won't see the state change"
    fi
    if ! grep -q "lock_poke_show()" <<< "$body"; then
        fail_link "link 4 (hamUId.ad): ${hook}() does NOT call lock_poke_show - the client never gets woken"
    fi
done
# spawn must be called from daemon startup.
if ! grep -q "lock_spawn(" "$HAMUID_SRC"; then
    fail_link "link 4 (hamUId.ad): lock_spawn is never called - the client is never launched"
fi
# It must spawn the SEPARATE-PROCESS hamlock binary, not draw inline.
if ! grep -q '"/bin/hamlock"' "$HAMUID_SRC"; then
    fail_link "link 4 (hamUId.ad): the compositor does NOT spawn /bin/hamlock - extraction is just a comment, not a behaviour change"
fi
# drain_verify must run in the daemon main loop.
if ! grep -q "lock_drain_verify(" "$HAMUID_SRC"; then
    fail_link "link 4 (hamUId.ad): lock_drain_verify is never called - the verify slot is unread"
fi

# --- Link 5: publish + drain paths use the kernel files -------------
pub_body=$(awk '
    /^def[[:space:]]+lock_publish_snapshot[[:space:]]*\(/ { inside=1; print; next }
    /^def[[:space:]]/ { if (inside) { inside=0 } }
    inside { print }
' "$HAMUID_SRC")
if ! grep -q '"/dev/wsys/ctl"' <<< "$pub_body"; then
    fail_link "link 5 (hamUId.ad): lock_publish_snapshot does NOT write /dev/wsys/ctl - the model never reaches the kernel"
fi
if ! grep -q '"lock "' <<< "$pub_body"; then
    fail_link "link 5 (hamUId.ad): lock_publish_snapshot does NOT emit the 'lock' verb - the kernel won't accept the payload"
fi
poke_body=$(awk '
    /^def[[:space:]]+lock_poke_show[[:space:]]*\(/ { inside=1; print; next }
    /^def[[:space:]]/ { if (inside) { inside=0 } }
    inside { print }
' "$HAMUID_SRC")
if ! grep -q '"/dev/wsys/lock/show"' <<< "$poke_body"; then
    fail_link "link 5 (hamUId.ad): lock_poke_show does NOT write /dev/wsys/lock/show - the show-serial never bumps"
fi
drain_body=$(awk '
    /^def[[:space:]]+lock_drain_verify[[:space:]]*\(/ { inside=1; print; next }
    /^def[[:space:]]/ { if (inside) { inside=0 } }
    inside { print }
' "$HAMUID_SRC")
if ! grep -q '"/dev/wsys/lock/verify"' <<< "$drain_body"; then
    fail_link "link 5 (hamUId.ad): lock_drain_verify does NOT read /dev/wsys/lock/verify - the watcher is wired to nothing"
fi
if ! grep -q "lock_pw_try" <<< "$drain_body"; then
    fail_link "link 5 (hamUId.ad): lock_drain_verify does NOT call lock_pw_try - a posted password never reaches the secret check"
fi

if [ "$fail" -ne 0 ]; then
    echo "FAIL: lock v2 extraction BROKEN (see link(s) above)" >&2
    exit 1
fi

echo "PASS: lock v2 extraction intact"
exit 0
