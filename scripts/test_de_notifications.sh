#!/usr/bin/env bash
# scripts/test_de_notifications.sh — scene-native notification wiring guard.
#
# In the production runlevel-5 scene DE the kernel scene compositor owns
# /dev/fb and the legacy hamUId-blit notification clients (hamnotif/hamtray)
# paint nothing. The scene-native notification system is:
#
#   publisher (hamnotify / welcome svc) --> /dev/wsys/post (kernel inbox ring)
#       --> panel BROKER (hampanelscene drains the ring) -->
#           * spawns /bin/hamtoast  (transient top-right toast scene client)
#           * logs to /tmp/hamnix-notif.log (inbox history)
#           * bumps the tray bell unread badge
#       tray bell click --> spawns /bin/haminbox (scene inbox, reads the log)
#
# This guard pins every load-bearing link so the pipeline can't silently
# regress (the legacy one did, across 100+ commits, with no test watching).
#
# Pass marker: PASS: DE notifications wired (scene-native)
# Fail marker: FAIL: <which link broke>

set -euo pipefail

PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

PANEL_SRC="user/hampanelscene.ad"
TOAST_SRC="user/hamtoast.ad"
INBOX_SRC="user/haminbox.ad"
WELCOME_SVC="etc/services.d/hamnotify-welcome.svc"
BUILD_USER="scripts/build_user.sh"
PKGS="scripts/build_packages.py"

fail=0
fail_link() {
    echo "FAIL: $1" >&2
    fail=1
}

for f in "$PANEL_SRC" "$TOAST_SRC" "$INBOX_SRC" "$WELCOME_SVC" \
         "$BUILD_USER" "$PKGS"; do
    if [ ! -f "$f" ]; then
        echo "FAIL: $f missing" >&2
        exit 1
    fi
done

# --- Link 1: toast + inbox are SCENE clients (commit to /dev/wsys/<wid>/scene)
for f in "$TOAST_SRC" "$INBOX_SRC"; do
    if ! grep -q "hamscene_commit" "$f"; then
        fail_link "link 1 ($f): not a scene client (no hamscene_commit) — won't render in the scene DE"
    fi
    if grep -q "hamui_v2_" "$f"; then
        fail_link "link 1 ($f): uses dead hamui_v2 blit path — paints nothing in the scene DE"
    fi
done

# --- Link 2: the panel BROKER drains the kernel inbox ring -----------
if ! grep -q "/dev/wsys/post" "$PANEL_SRC"; then
    fail_link "link 2 ($PANEL_SRC): panel never reads /dev/wsys/post — notifications are never drained"
fi
if ! grep -qE '"ack ' "$PANEL_SRC"; then
    fail_link "link 2 ($PANEL_SRC): panel never ACKs drained slots — the kernel ring head never advances"
fi

# --- Link 3: the broker spawns the toast + logs the inbox history ----
if ! grep -q "/bin/hamtoast" "$PANEL_SRC"; then
    fail_link "link 3 ($PANEL_SRC): broker never spawns /bin/hamtoast — no toast pops"
fi
if ! grep -q "/tmp/hamnix-notif.log" "$PANEL_SRC"; then
    fail_link "link 3 ($PANEL_SRC): broker never writes the inbox history log"
fi
if ! grep -q "/tmp/hamnix-notif.log" "$INBOX_SRC"; then
    fail_link "link 3 ($INBOX_SRC): inbox never reads the history log"
fi

# --- Link 4: the tray bell opens the scene inbox + shows the badge ---
if ! grep -q "/bin/haminbox" "$PANEL_SRC"; then
    fail_link "link 4 ($PANEL_SRC): tray click never spawns /bin/haminbox"
fi
if ! grep -q "notif_unread" "$PANEL_SRC"; then
    fail_link "link 4 ($PANEL_SRC): no unread-count state — tray badge can't render"
fi

# --- Link 5: the welcome publisher still posts via /dev/wsys/post ----
if ! grep -q "/bin/hamnotify" "$WELCOME_SVC"; then
    fail_link "link 5 ($WELCOME_SVC): welcome notification publisher is gone"
fi

# --- Link 6: both new binaries are registered to build + ship --------
for stem in hamtoast haminbox; do
    if ! grep -q "build_adder_user ${stem}\b" "$BUILD_USER"; then
        fail_link "link 6 ($BUILD_USER): ${stem} is not registered to build"
    fi
    if ! grep -q "\"${stem}\"" "$PKGS"; then
        fail_link "link 6 ($PKGS): ${stem} is not in DESKTOP_APP_BINS — won't ship in the desktop package"
    fi
done

if [ "$fail" -ne 0 ]; then
    echo "FAIL: DE notification guard tripped (see link(s) above)" >&2
    exit 1
fi

echo "PASS: DE notifications wired (scene-native)"
exit 0
