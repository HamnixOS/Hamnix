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

# --- 3c. GUI install progress STREAMING (regression: "installing from
# repo" hang) -------------------------------------------------------------
# The GUI froze forever on "installing from repo ..." because it redirected
# only the install child's stdout to a /tmp file via an integer-fd dup2 (which
# lib/p9 spawn silently SKIPS when the fd number is >= 16) and dropped stderr
# entirely — so a real install failure printed only to fd 2 and was never seen.
# The fix routes BOTH stdout (fd 1) and stderr (fd 2) through a pipe the GUI
# drains non-blocking, detects the child's completion/FAIL markers, AND
# surfaces a clean pipe-EOF so a child that exits without a marker no longer
# hangs the pane. Guard every load-bearing piece of that data path.
if grep -q 'sys_pipechan()' user/haminstallui.ad \
        && grep -q 'DEVFD_PIPE_R' user/haminstallui.ad \
        && grep -q 'DEVFD_PIPE_W' user/haminstallui.ad; then
    passed "haminstallui captures install output through a pipe (not a /tmp file)"
else
    failed "haminstallui install-output capture is not pipe-based (fd>=16 redirect trap)"
fi
# The install child must be spawned with the stdio-namespace sentinel for BOTH
# stdin and stdout so the post-spawn fdbinds (fd 1 AND fd 2 -> the pipe) land.
if grep -q 'SPAWN_STDIO_NS, SPAWN_STDIO_NS' user/haminstallui.ad; then
    passed "haminstallui spawns /bin/install with SPAWN_STDIO_NS stdio"
else
    failed "haminstallui does not spawn install with SPAWN_STDIO_NS (fdbind won't take)"
fi
# Both fd 1 and fd 2 of the child must be bound to the pipe WRITE end so the
# installer's stderr FAIL lines reach the pane (the original drop that hid the
# failure and produced the hang).
if grep -q 'sys_fdbind(pid, 1, DEVFD_PIPE_W' user/haminstallui.ad \
        && grep -q 'sys_fdbind(pid, 2, DEVFD_PIPE_W' user/haminstallui.ad; then
    passed "haminstallui binds child stdout AND stderr to the progress pipe"
else
    failed "haminstallui does not capture child stderr (FAIL lines invisible -> hang)"
fi
# The poll loop must be non-blocking (sys_read_nb) and treat a pipe EOF (-1)
# as terminal so an install that exits without a marker can't freeze the pane.
if grep -q 'sys_read_nb(inst_out_fd' user/haminstallui.ad \
        && grep -q 'inst_eof' user/haminstallui.ad \
        && grep -q "installer exited without 'install complete'" user/haminstallui.ad; then
    passed "haminstallui drains the pipe non-blocking + handles EOF-without-marker"
else
    failed "haminstallui poll loop missing non-blocking drain / EOF-without-marker guard"
fi
# The completion + failure markers the GUI scans for must match what
# /bin/install actually prints to stdout/stderr ("install complete" / "FAIL").
if grep -q '"install complete"' user/haminstallui.ad \
        && grep -q '"FAIL"' user/haminstallui.ad \
        && grep -q 'install complete on' user/install.ad \
        && grep -q '\[install\] FAIL' user/install.ad; then
    passed "haminstallui completion/FAIL markers match /bin/install output"
else
    failed "haminstallui markers do not match /bin/install output (pane can't detect done)"
fi
# The legacy /tmp log-file redirect path must be gone (it was the fd>=16 trap).
if grep -vE '^\s*#' user/haminstallui.ad | grep -q 'haminstall.gui.log'; then
    failed "haminstallui still uses the /tmp log-file redirect (fd>=16 dup2 trap)"
else
    passed "haminstallui no longer uses the fragile /tmp log-file redirect"
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
