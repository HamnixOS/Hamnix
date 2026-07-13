#!/usr/bin/env bash
# scripts/test_de_lock_v2.sh — structural guard for the DE screen lock.
#
# HISTORY: the lock overlay was once rendered inline by the hamUId
# daemon_pixel monolith, then extracted to a v2-blit /bin/hamlock whose
# locked/unlocked MODEL was owned by the hamUId compositor (published on
# /dev/wsys/lock). In the scene-file DE that daemon is retired — at
# runlevel 5 hamUId does the `desktop` flip and EXITS — so a
# compositor-owned lock model never gets published and that hamlock
# painted nothing. #138 rewrote hamlock as a SELF-CONTAINED scene lock
# client: it owns its full-screen window, draws its own curtain + masked
# password field, reads its own keystrokes, and makes the unlock DECISION
# itself by authenticating against /dev/auth. On success it closes its own
# window via the per-window /ctl `close` verb (which recomposites the
# desktop beneath) and exits. hamsessui's "Lock Screen" row spawns it.
#
# This guard asserts that self-contained wiring stays intact.
#
# Pass marker:  PASS: lock scene client intact
# Fail marker:  FAIL: <which link broke>

set -euo pipefail

PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

KERN_SRC="sys/src/9/port/devwsys.ad"
HAMUID_SRC="user/hamUId.ad"
LOCK_SRC="user/hamlock.ad"
SESSUI_SRC="user/hamsessui.ad"
BUILD_SRC="scripts/build_user.sh"

fail=0
fail_link() {
    echo "FAIL: $1" >&2
    fail=1
}

for f in "$KERN_SRC" "$HAMUID_SRC" "$LOCK_SRC" "$SESSUI_SRC" "$BUILD_SRC"; do
    if [ ! -f "$f" ]; then
        echo "FAIL: $f missing" >&2
        exit 1
    fi
done

# --- Link 1: the legacy lock-pixel render is GONE from daemon_pixel -----
# The old overlay rendered "Screen Locked" / "Click to unlock" inline via
# str_ink, gated on `if LOCKED != 0:`. Those literals must not be back in
# hamUId's daemon_pixel (they belong to the standalone client now).
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
        fail_link "link 1 (hamUId.ad): daemon_pixel still references '$sym' - lock overlay leaked back into the monolith"
    fi
done

# --- Link 2: hamlock is built + is a SELF-CONTAINED scene lock client ----
if ! grep -q "build_adder_user hamlock" "$BUILD_SRC"; then
    fail_link "link 2 (build_user.sh): hamlock is not built - the binary won't ship in the initramfs"
fi
# Scene client (not the retired v2-blit path): draws via hamscene_*.
if ! grep -q "hamscene_commit" "$LOCK_SRC"; then
    fail_link "link 2 (hamlock.ad): does NOT call hamscene_commit - it isn't a scene client"
fi
# Reads its OWN keystrokes from the per-window /keys leaf.
if ! grep -q '"/keys"' "$LOCK_SRC"; then
    fail_link "link 2 (hamlock.ad): does NOT open the per-window /keys leaf - it can't read the password"
fi
# Renders the lock curtain title.
if ! grep -q '"Screen Locked"' "$LOCK_SRC"; then
    fail_link "link 2 (hamlock.ad): does NOT render the 'Screen Locked' curtain"
fi

# --- Link 3: hamlock owns the unlock DECISION via /dev/auth -------------
if ! grep -q '"/dev/auth"' "$LOCK_SRC"; then
    fail_link "link 3 (hamlock.ad): does NOT authenticate via /dev/auth - a lock with no secret check is not a lock"
fi
if ! grep -q '"user "' "$LOCK_SRC" || ! grep -q '"pass "' "$LOCK_SRC"; then
    fail_link "link 3 (hamlock.ad): missing the /dev/auth 'user '/'pass ' handshake lines"
fi
# On unlock it closes its OWN window so the desktop repaints.
if ! grep -q '"close' "$LOCK_SRC"; then
    fail_link "link 3 (hamlock.ad): does NOT write the per-window 'close' verb - the curtain would stay on screen after unlock"
fi

# --- Link 4: hamsessui's Lock Screen row spawns /bin/hamlock ------------
if ! grep -q '"/bin/hamlock"' "$SESSUI_SRC"; then
    fail_link "link 4 (hamsessui.ad): the End-Session dialog does NOT spawn /bin/hamlock - Lock Screen is unwired"
fi

# --- Link 5: kernel per-window /ctl exposes the 'close' verb ------------
winctl_body=$(awk '
    /^def[[:space:]]+devwsys_winctl_write[[:space:]]*\(/ { inside=1; print; next }
    /^def[[:space:]]/ { if (inside) { inside=0 } }
    inside { print }
' "$KERN_SRC")
if [ -z "$winctl_body" ]; then
    fail_link "link 5 (devwsys.ad): devwsys_winctl_write() not found"
fi
if ! grep -q '"close"' <<< "$winctl_body"; then
    fail_link "link 5 (devwsys.ad): per-window /ctl has no 'close' verb - a client can't tear down its own window"
fi
if ! grep -q "_wsys_close_window" <<< "$winctl_body"; then
    fail_link "link 5 (devwsys.ad): the 'close' verb does NOT route to _wsys_close_window - the vacated footprint won't recompose"
fi

if [ "$fail" -ne 0 ]; then
    echo "FAIL: lock scene client BROKEN (see link(s) above)" >&2
    exit 1
fi

echo "PASS: lock scene client intact"
exit 0
