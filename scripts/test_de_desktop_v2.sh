#!/usr/bin/env bash
# scripts/test_de_desktop_v2.sh — DE pivot wave 1 (round 2) structural
# guard: the desktop icon badge layer is no longer drawn by
# daemon_pixel's dpix_root_icons call. It now lives in /bin/hamdesktop, a
# v2 client that reads its model from /dev/wsys/desktop and is woken by
# writes to /dev/wsys/desktop/show.
#
# Pass marker:  PASS: desktop v2 extraction intact
# Fail marker:  FAIL: <which link broke>

set -euo pipefail

PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

KERN_SRC="sys/src/9/port/devwsys.ad"
NAMEC_SRC="sys/src/9/port/namec.ad"
HAMUID_SRC="user/hamUId.ad"
DESKTOP_SRC="user/hamdesktop.ad"
BUILD_SRC="scripts/build_user.sh"

fail=0
fail_link() {
    echo "FAIL: $1" >&2
    fail=1
}

for f in "$KERN_SRC" "$NAMEC_SRC" "$HAMUID_SRC" "$DESKTOP_SRC" "$BUILD_SRC"; do
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
if grep -qE "dpix_root_icons\(" <<< "$daemon_pixel_body"; then
    fail_link "link 1 (hamUId.ad): daemon_pixel still calls dpix_root_icons - desktop rendering did not extract"
fi
if ! grep -q "desktop icon.*EXTRACTED" <<< "$daemon_pixel_body"; then
    fail_link "link 1 (hamUId.ad): the 'desktop icon ... EXTRACTED' breadcrumb is gone"
fi

# --- Link 2: hamdesktop binary is registered + is a SCENE client ----
# hamdesktop was rewritten onto the scene-file DE: it is now an ordinary
# scene client (display list via lib/hamui hamscene_*), NOT the retired
# hamui_v2 bitmap-blit client. The structural contract is: it is built, it
# emits a scene via hamscene_commit, it draws icons with the scene icon
# helpers, and it renders its icon set from the REAL desktop DIRECTORY
# (~/Desktop) — parsing `.desktop` launchers + showing files/folders — so
# `ls ~/Desktop` shows the icons and a CLI-created folder appears on a
# periodic re-scan.
RC5_SRC="etc/rc.d/rc.5"
if ! grep -q "build_adder_user hamdesktop" "$BUILD_SRC"; then
    fail_link "link 2 (build_user.sh): hamdesktop is not built"
fi
if ! grep -q "hamscene_commit" "$DESKTOP_SRC"; then
    fail_link "link 2 (hamdesktop.ad): does NOT emit a scene via hamscene_commit"
fi
if ! grep -qE "hamscene_icon_folder|hamscene_icon_file" "$DESKTOP_SRC"; then
    fail_link "link 2 (hamdesktop.ad): does NOT draw scene icon glyphs"
fi
# Directory-backed icon source: it points at ~/Desktop, lists it through the
# shared FM directory scanner, and parses `.desktop` launcher files.
if ! grep -q '"/home/live/Desktop"' "$DESKTOP_SRC"; then
    fail_link "link 2 (hamdesktop.ad): does NOT target the ~/Desktop directory"
fi
if ! grep -q 'fmc_load_dir' "$DESKTOP_SRC"; then
    fail_link "link 2 (hamdesktop.ad): does NOT scan the desktop dir (fmc_load_dir)"
fi
if ! grep -q 'desktop_parse' "$DESKTOP_SRC"; then
    fail_link "link 2 (hamdesktop.ad): does NOT parse .desktop launcher files"
fi
# Periodic external-change re-scan so a CLI-created folder/file appears.
if ! grep -q 'fmc_refresh_if_changed' "$DESKTOP_SRC"; then
    fail_link "link 2 (hamdesktop.ad): missing the periodic dir re-scan (fmc_refresh_if_changed)"
fi
# The default launcher template ships as REAL .desktop files under
# /etc/skel/Desktop (build_initramfs plants them at /home/live/Desktop).
if ! ls etc/skel/Desktop/*.desktop >/dev/null 2>&1; then
    fail_link "link 2 (etc/skel/Desktop): no default .desktop launcher template shipped"
fi
if ! grep -q 'skel.*Desktop\|Desktop.*desktop' scripts/build_initramfs.py; then
    fail_link "link 2 (build_initramfs.py): does NOT plant the ~/Desktop launcher template"
fi
if [ -f "$RC5_SRC" ] && ! grep -q "/bin/hamdesktop" "$RC5_SRC"; then
    fail_link "link 2 (rc.5): hamdesktop is not launched at runlevel 5"
fi

# --- Link 3: kernel exposes /dev/wsys/desktop + show leaves --------
for sym in "DEV_WSYS_DESKTOP\b" "DEV_WSYS_DESKTOP_SHOW"; do
    if ! grep -qE "${sym}" "$NAMEC_SRC"; then
        fail_link "link 3 (namec.ad): DEV constant ${sym} is missing"
    fi
done
for fn in devwsys_desktop_read devwsys_desktop_show_read devwsys_desktop_show_write; do
    if ! grep -qE "def[[:space:]]+${fn}[[:space:]]*\(" "$KERN_SRC"; then
        fail_link "link 3 (devwsys.ad): ${fn}() definition is missing"
    fi
    if ! grep -q "${fn}" "$NAMEC_SRC"; then
        fail_link "link 3 (namec.ad): ${fn} is not wired into the dispatcher"
    fi
done
if ! grep -q '"desktop/show"' "$NAMEC_SRC"; then
    fail_link "link 3 (namec.ad): desktop/show path is not resolved"
fi
if ! grep -q '"desktop"' "$NAMEC_SRC"; then
    fail_link "link 3 (namec.ad): desktop path is not resolved"
fi
if ! grep -E "_wsys_ctl_word_eq" "$KERN_SRC" | grep -q '"desktop"'; then
    fail_link "link 3 (devwsys.ad): /dev/wsys/ctl 'desktop' verb is missing"
fi

# --- Link 4: compositor publishes, spawns, and pokes ---------------
for fn in desktop_publish_snapshot desktop_spawn desktop_poke_show desktop_publish_if_changed; do
    if ! grep -qE "def[[:space:]]+${fn}[[:space:]]*\(" "$HAMUID_SRC"; then
        fail_link "link 4 (hamUId.ad): ${fn}() definition is missing"
    fi
done
if ! grep -q "desktop_spawn(" "$HAMUID_SRC"; then
    fail_link "link 4 (hamUId.ad): desktop_spawn is never called"
fi
if ! grep -q '"/bin/hamdesktop"' "$HAMUID_SRC"; then
    fail_link "link 4 (hamUId.ad): the compositor does NOT spawn /bin/hamdesktop"
fi
post_present_body=$(awk '
    /^def[[:space:]]+post_present_overlays[[:space:]]*\(/ { inside=1; print; next }
    /^def[[:space:]]/ { if (inside) { inside=0 } }
    inside { print }
' "$HAMUID_SRC")
if ! grep -q "desktop_publish_if_changed()" <<< "$post_present_body"; then
    fail_link "link 4 (hamUId.ad): post_present_overlays does NOT call desktop_publish_if_changed"
fi

# --- Link 5: publish path uses the kernel files --------------------
pub_body=$(awk '
    /^def[[:space:]]+desktop_publish_snapshot[[:space:]]*\(/ { inside=1; print; next }
    /^def[[:space:]]/ { if (inside) { inside=0 } }
    inside { print }
' "$HAMUID_SRC")
if ! grep -q '"/dev/wsys/ctl"' <<< "$pub_body"; then
    fail_link "link 5 (hamUId.ad): desktop_publish_snapshot does NOT write /dev/wsys/ctl"
fi
if ! grep -q '"desktop "' <<< "$pub_body"; then
    fail_link "link 5 (hamUId.ad): desktop_publish_snapshot does NOT emit the 'desktop' verb"
fi
poke_body=$(awk '
    /^def[[:space:]]+desktop_poke_show[[:space:]]*\(/ { inside=1; print; next }
    /^def[[:space:]]/ { if (inside) { inside=0 } }
    inside { print }
' "$HAMUID_SRC")
if ! grep -q '"/dev/wsys/desktop/show"' <<< "$poke_body"; then
    fail_link "link 5 (hamUId.ad): desktop_poke_show does NOT write /dev/wsys/desktop/show"
fi

if [ "$fail" -ne 0 ]; then
    echo "FAIL: desktop v2 extraction BROKEN (see link(s) above)" >&2
    exit 1
fi

echo "PASS: desktop v2 extraction intact"
exit 0
