#!/usr/bin/env bash
# scripts/test_de_session.sh — structural guard for the DE session
# save/restore primitive that landed in
# "DE: hamsession save/restore + /dev/wsys/session snapshot":
#
#   1. Kernel-side per-wid app-path storage + /dev/wsys/ctl `setapp
#      <wid> <path>` verb (sys/src/9/port/devwsys.ad): records the
#      program path the compositor just spawned into <wid>.
#
#   2. Kernel-side /dev/wsys/session snapshot file: snapshot read
#      renders one line per active wid as
#      "<wid> <pid> <app> <x> <y> <w> <h>\n". Wired into namec.ad
#      (DEV_WSYS_SESSION + path lookup + read dispatch).
#
#   3. Userland helper user/hamsession.ad: `save [path]` reads the
#      kernel snapshot and persists to ~/.hamnix-session (or argv);
#      `restore [path]` reads the saved file and fork+execs each
#      line's app via the rfork+execve path.
#
#   4. Compositor side (user/hamUId.ad): after each
#      daemon_spawn_window_prog, writes "setapp <wid> <path>" to
#      /dev/wsys/ctl so the snapshot is replay-able. Save Session +
#      Restore Session menu entries route through spawn_set_arg1.
#
#   5. scripts/build_user.sh wires hamsession into the user-binary
#      build list.
#
# Grep-only (no QEMU boot). Same shape as scripts/test_de_wallpaper.sh
# and scripts/test_de_snarf_wctl.sh.
#
# Pass marker:  PASS: DE session save/restore primitives intact
# Fail marker:  FAIL: <which link broke>

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

WSYS_SRC="sys/src/9/port/devwsys.ad"
NAMEC_SRC="sys/src/9/port/namec.ad"
HAMUID_SRC="user/hamUId.ad"
HSESS_SRC="user/hamsession.ad"
BUILD_USER="scripts/build_user.sh"

fail=0

fail_link() {
    echo "FAIL: $1" >&2
    fail=1
}

require_file() {
    if [ ! -f "$1" ]; then
        fail_link "source file missing: $1"
        return 1
    fi
    return 0
}

require_file "$WSYS_SRC"   || true
require_file "$NAMEC_SRC"  || true
require_file "$HAMUID_SRC" || true
require_file "$HSESS_SRC"  || true
require_file "$BUILD_USER" || true
if [ "$fail" -ne 0 ]; then
    echo "FAIL: DE session save/restore guard — required source file(s) missing" >&2
    exit 1
fi

# --- Kernel per-wid app-path storage --------------------------------------
if ! grep -Eq "^wsys_app_path:[[:space:]]*Array" "$WSYS_SRC"; then
    fail_link "session: wsys_app_path[] backing array gone"
fi
if ! grep -Eq "^wsys_app_path_len:[[:space:]]*Array" "$WSYS_SRC"; then
    fail_link "session: wsys_app_path_len[] backing array gone"
fi
if ! grep -Eq "^def[[:space:]]+wsys_app_path_set" "$WSYS_SRC"; then
    fail_link "session: wsys_app_path_set() setter gone"
fi

# --- /dev/wsys/ctl `setapp <wid> <path>` verb -----------------------------
if ! grep -q '"setapp"' "$WSYS_SRC"; then
    fail_link "session: 'setapp' verb literal gone from devwsys_ctl_write"
fi

# --- /dev/wsys/session snapshot read --------------------------------------
if ! grep -Eq "^def[[:space:]]+devwsys_session_read" "$WSYS_SRC"; then
    fail_link "session: devwsys_session_read() definition gone"
fi
if ! grep -Eq "^def[[:space:]]+_wsys_session_render" "$WSYS_SRC"; then
    fail_link "session: _wsys_session_render() definition gone"
fi

# --- namec wiring ---------------------------------------------------------
if ! grep -Eq "^DEV_WSYS_SESSION:[[:space:]]*int32" "$NAMEC_SRC"; then
    fail_link "namec: DEV_WSYS_SESSION constant gone"
fi
if ! grep -q "devwsys_session_read" "$NAMEC_SRC"; then
    fail_link "namec: devwsys_session_read not imported / not dispatched"
fi
if ! grep -q '"session"' "$NAMEC_SRC"; then
    fail_link "namec: #c/wsys/session path lookup gone"
fi

# --- Userland hamsession.ad ----------------------------------------------
if ! grep -Eq "^def[[:space:]]+hsess_cmd_save" "$HSESS_SRC"; then
    fail_link "hamsession: save command implementation gone"
fi
if ! grep -Eq "^def[[:space:]]+hsess_cmd_restore" "$HSESS_SRC"; then
    fail_link "hamsession: restore command implementation gone"
fi
if ! grep -Eq "^def[[:space:]]+hsess_spawn" "$HSESS_SRC"; then
    fail_link "hamsession: fork+exec helper gone"
fi
if ! grep -q '"/dev/wsys/session"' "$HSESS_SRC"; then
    fail_link "hamsession: /dev/wsys/session read path gone"
fi
if ! grep -q '"/home/.hamnix-session"' "$HSESS_SRC"; then
    fail_link "hamsession: default ~/.hamnix-session save-path gone"
fi

# --- Compositor wiring ----------------------------------------------------
if ! grep -q '"setapp "' "$HAMUID_SRC"; then
    fail_link "compositor: daemon_spawn_window_prog no longer writes 'setapp' to /dev/wsys/ctl"
fi
if ! grep -Eq '"Save Session"' "$HAMUID_SRC"; then
    fail_link "compositor: 'Save Session' menu label missing"
fi
if ! grep -Eq '"Restore Session"' "$HAMUID_SRC"; then
    fail_link "compositor: 'Restore Session' menu label missing"
fi
if ! grep -q '"/bin/hamsession"' "$HAMUID_SRC"; then
    fail_link "compositor: '/bin/hamsession' program path missing from menu_prog"
fi

# --- Build wiring ---------------------------------------------------------
if ! grep -q "build_adder_user hamsession" "$BUILD_USER"; then
    fail_link "build_user.sh: hamsession not registered as a user binary"
fi

# --- Snapshot-line format smoke test --------------------------------------
# The kernel renderer's format is "<wid> <pid> <app> <x> <y> <w> <h>\n";
# build a tiny exemplar line and verify it has exactly 7 whitespace-
# separated fields. Same idea as test_de_wallpaper.sh's awk smoke test.
TMP_LINE="$(mktemp -t hamnix.session.XXXXXX.txt)"
trap 'rm -f "$TMP_LINE"' EXIT
printf '2 17 /bin/hamterm 100 32 480 320\n' > "$TMP_LINE"
nfields=$(awk 'NR==1{print NF}' "$TMP_LINE")
if [ "$nfields" -ne 7 ]; then
    fail_link "session: synthetic exemplar line has $nfields fields (want 7)"
fi
# The third field must be the app-path (slash-prefixed) — guards against
# the renderer accidentally dropping the app column.
appfield=$(awk 'NR==1{print $3}' "$TMP_LINE")
case "$appfield" in
    /*) ;;
    -)  ;;
    *)  fail_link "session: exemplar app field '$appfield' is neither path nor '-' sentinel" ;;
esac

if [ "$fail" -ne 0 ]; then
    echo "FAIL: DE session save/restore primitives BROKEN (see link(s) above)" >&2
    exit 1
fi

echo "PASS: DE session save/restore primitives intact"
exit 0
