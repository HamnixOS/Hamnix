#!/usr/bin/env bash
# scripts/test_de_spawn_detached.sh — DE fire-and-forget launch leak guard.
#
# ROOT CAUSE this pins (the "app-menu launch breaks after a few" + "hamedit
# won't re-open from the file manager" DE bugs): the DE's long-running service
# parents — the scene panel (hampanelscene), the desktop (hamdesktop), the
# file manager (hamfmscene) — fire off apps/editors and NEVER wait4 them. With
# the plain lib/p9.ad spawn() those children are published as NON-detached
# zombies on exit; reap_orphan_zombies() (run by the kernel at every fork)
# only reclaims a zombie that is DETACHED or ORPHANED (parent gone), so a
# child whose parent is STILL ALIVE leaks its whole address space waiting for
# a wait4 that never comes. After a handful of launches/closes fork() hits
# -EAGAIN and the menu / re-open silently stops working.
#
# FIX: those launchers must use spawn_detached() (RFNOWAIT), so the kernel
# reclaims each child at exit. This guard asserts:
#   1. lib/p9.ad defines spawn_detached + P9_RFNOWAIT.
#   2. The DE launch sites route through spawn_detached, NOT the plain spawn.
#
# Pass marker: PASS: DE launchers detached (no fork-EAGAIN leak)

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

P9="lib/p9.ad"
fail=0
note() { echo "FAIL: $1" >&2; fail=1; }

# --- Link 1: the detached spawn primitive exists ---------------------
if ! grep -q "def spawn_detached(" "$P9"; then
    note "lib/p9.ad: spawn_detached() is gone — DE launchers cannot detach"
fi
if ! grep -qE "P9_RFNOWAIT.*0x100" "$P9"; then
    note "lib/p9.ad: P9_RFNOWAIT (0x100) constant missing — detach flag lost"
fi

# --- Link 2: each launcher routes its fire-and-forget spawn detached -
# For each (file, function-or-context) the launch call must be spawn_detached.
# We grep the launch call site directly.

# panel: _launch (app menu rows) + _spawn_toast
if ! grep -q "spawn_detached(prog" user/hampanelscene.ad; then
    note "hampanelscene.ad: _launch() not detached — app-menu launches leak"
fi
if ! grep -q 'spawn_detached(cast\[Ptr\[char\]\]("/bin/hamtoast")' user/hampanelscene.ad; then
    note "hampanelscene.ad: _spawn_toast() not detached — toasts leak"
fi

# file manager: editor open (re-open bug)
if ! grep -q "spawn_detached(cast\[Ptr\[char\]\](&ED_BIN\[0\])" user/hamfmscene.ad; then
    note "hamfmscene.ad: _open_in_editor() not detached — hamedit re-open leaks"
fi

# desktop: icon double-click launches (3 sites)
dt_detached=$(grep -c "spawn_detached(" user/hamdesktop.ad || true)
if [ "${dt_detached:-0}" -lt 3 ]; then
    note "hamdesktop.ad: expected >=3 spawn_detached launch sites, found ${dt_detached:-0}"
fi

# Belt-and-braces: no DE launcher still uses the leaky plain spawn() for a
# /bin app. (The terminal's hamsh child is a deliberate 1:1 waited child and
# is exempt — it lives/dies with the terminal and is reaped on terminal exit.)
if grep -nE "[^_]spawn\((cast\[Ptr\[char\]\]\(&?(launch_path|spawn_path|ED_BIN)|prog," \
        user/hampanelscene.ad user/hamfmscene.ad user/hamdesktop.ad >/dev/null 2>&1; then
    note "a DE launcher still uses the leaky plain spawn() — re-leak introduced"
fi

if [ "$fail" -ne 0 ]; then
    echo "FAIL: DE spawn-detached guard tripped" >&2
    exit 1
fi
echo "PASS: DE launchers detached (no fork-EAGAIN leak)"
exit 0
