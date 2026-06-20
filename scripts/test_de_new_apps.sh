#!/usr/bin/env bash
# scripts/test_de_new_apps.sh
#
# FAST regression guard for the DE features wave (no VM / KVM needed):
#
#   1. The three new scene apps COMPILE clean to user ELFs:
#        haminstallui  — visual installer GUI front-end over /bin/install
#        hamsettings   — wallpaper + panel settings
#        hammonscene   — system monitor (uptime/mem/process list)
#   2. hamdesktop COMPILES with the icon drag-rearrange + persist logic.
#   3. Each new app is REGISTERED: built by build_user.sh, listed in the
#      Applications menu (hampanelscene), and present in /etc/desktop.icons.
#   4. The desktop-icon DRAG-PERSIST wiring is present: hamdesktop parses the
#      optional "|x|y" position fields, writes them back, and the persisted
#      /etc/desktop.icons format is round-trippable (parser accepts the
#      extended 5-field line AND the legacy 3-field line).
#
# These are the load-bearing invariants a later refactor could silently
# break; the heavy VM gates (test_de_scene_*) prove the live visuals. This
# gate is the cheap always-runs companion.

set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

fail=0
note() { echo "[de_new_apps] $*"; }
failed() { echo "[de_new_apps] FAIL $*" >&2; fail=1; }
passed() { echo "[de_new_apps] PASS $*"; }

# --- 1/2. Compile each app to a user ELF -----------------------------
compile_one() {
    local name="$1"
    local out
    out="$(mktemp --tmpdir "hamnix-${name}.XXXXXX.elf")"
    if python3 -m compiler.adder compile --target=x86_64-adder-user \
            "user/${name}.ad" -o "$out" >/tmp/de_new_apps.$name.log 2>&1; then
        if file "$out" | grep -q ELF; then
            passed "$name compiles to an ELF"
        else
            failed "$name produced no ELF"
        fi
    else
        failed "$name did NOT compile (see /tmp/de_new_apps.$name.log)"
        tail -5 "/tmp/de_new_apps.$name.log" >&2 || true
    fi
    rm -f "$out"
}

for app in haminstallui hamsettings hammonscene hamdesktop; do
    compile_one "$app"
done

# --- 3. Registration: build_user.sh + Applications menu + desktop icons
for app in haminstallui hamsettings hammonscene; do
    if grep -q "build_adder_user ${app}\b" scripts/build_user.sh; then
        passed "$app registered in build_user.sh"
    else
        failed "$app NOT in build_user.sh"
    fi
done

# Applications menu (hampanelscene) launches each new app.
for prog in haminstallui hamsettings hammonscene; do
    if grep -q "/bin/${prog}" user/hampanelscene.ad; then
        passed "$prog wired into the Applications menu"
    else
        failed "$prog NOT in the Applications menu (hampanelscene)"
    fi
done

# Desktop icons reference each new app.
for prog in haminstallui hamsettings hammonscene; do
    if grep -q "/bin/${prog}" etc/desktop.icons; then
        passed "$prog has a desktop icon"
    else
        failed "$prog NOT in /etc/desktop.icons"
    fi
done

# --- 3b. GUI installer drives the PACKAGE-based install path ----------
# The GUI must spawn `/bin/install --auto` (Debian-style hpm package install)
# NOT the legacy `/bin/haminstall` (dd ESP + manifest rootfs copy that pulled
# bytes from /n/distros and failed with "skip missing source"). Guard both:
# the right binary is spawned, AND the GUI never references /n/distros.
if grep -q 'spawn(cast\[Ptr\[char\]\]("/bin/install")' user/haminstallui.ad \
        && grep -q '"--auto"' user/haminstallui.ad; then
    passed "haminstallui spawns /bin/install --auto (package-based install)"
else
    failed "haminstallui does NOT spawn /bin/install --auto (package path missing)"
fi
if grep -q 'spawn(cast\[Ptr\[char\]\]("/bin/haminstall")' user/haminstallui.ad; then
    failed "haminstallui still spawns the legacy /bin/haminstall (dd/manifest path)"
else
    passed "haminstallui no longer spawns the legacy /bin/haminstall"
fi
# Check code lines only (strip '#' comments) — the header doc may mention
# /n/distros to explain what it deliberately does NOT do.
if grep -vE '^\s*#' user/haminstallui.ad | grep -q '/n/distros'; then
    failed "haminstallui CODE references /n/distros (must source from the hpm repo only)"
else
    passed "haminstallui code never references /n/distros"
fi
# Online-repo option present + local fallback is the default.
if grep -q 'use_online' user/haminstallui.ad \
        && grep -q 'file:///iso-packages' user/haminstallui.ad; then
    passed "haminstallui offers an online-repo toggle with local-repo fallback"
else
    failed "haminstallui missing the online-repo toggle / local fallback"
fi

# --- 4. Desktop-icon drag-persist wiring -----------------------------
# hamdesktop must parse the optional position fields and write them back.
if grep -q '_save_config' user/hamdesktop.ad \
        && grep -q 'sys_open_write(cast\[Ptr\[char\]\]("/etc/desktop.icons"))' \
            user/hamdesktop.ad; then
    passed "hamdesktop persists the icon layout to /etc/desktop.icons"
else
    failed "hamdesktop missing the persist-on-drop path"
fi
if grep -q 'DRAG_THRESH' user/hamdesktop.ad \
        && grep -q 'dragging' user/hamdesktop.ad; then
    passed "hamdesktop has the click-vs-drag threshold logic"
else
    failed "hamdesktop missing the drag-threshold logic"
fi
# The config parser must still accept BOTH the 3-field legacy lines and the
# 5-field (with |x|y) persisted lines: confirm the shipped config + the
# optional-field parse branch are both present.
if grep -q 'ic_x\[n_icons\]' user/hamdesktop.ad \
        && grep -Eq '^[A-Za-z].*\|(folder|file)\|/bin/' etc/desktop.icons; then
    passed "hamdesktop config carries per-icon positions + legacy lines parse"
else
    failed "hamdesktop position fields / legacy config not round-trippable"
fi

if [ "$fail" = "0" ]; then
    echo "[de_new_apps] RESULT: PASS"
    exit 0
fi
echo "[de_new_apps] RESULT: FAIL"
exit 1
