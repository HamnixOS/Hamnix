#!/usr/bin/env bash
# scripts/test_de_panel_prefs.sh
#
# FAST regression guard (no VM / KVM needed) for three VM-reported DE bugs:
#
#   1. PANEL POSITION. Settings writes `position top|bottom` to
#      /etc/panel.conf; hampanelscene must (a) PARSE the position line
#      (it used to deliberately ignore it), (b) place the panel window at
#      the chosen screen edge, and (c) LIVE-RELOAD the config so the change
#      applies without a panel restart.
#   2. SYSMON APPLET TOGGLE. The `right sysmon` applet line, added/removed by
#      Settings, must be honoured on the live re-read (same reload path).
#   3. SYSTEM-MONITOR PROCESS LIST. /proc/tasks rendered every spawned
#      process with the creation-time "__rfork_" name0 tag (so the monitor
#      showed only "rfork" + "init"). do_execve must now stamp the running
#      program's basename into name0/comm so the list shows REAL names.
#
# These are source-level invariants a later refactor could silently break;
# the heavy VM gates prove the live visuals. This is the cheap always-runs
# companion. Everything here is a static assertion + a compile check.

set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

fail=0
failed() { echo "[panel_prefs] FAIL $*" >&2; fail=1; }
passed() { echo "[panel_prefs] PASS $*"; }

PANEL=user/hampanelscene.ad
CORE=kernel/sched/core.ad
SYSCALL=arch/x86/kernel/syscall.ad

# --- 1a. The panel PARSES the position/edge line (no longer ignores it) ----
# (The configurable-panels rewrite generalized panel_bottom into a per-panel
# `edge` with EDGE_TOP/EDGE_BOTTOM; the legacy `position bottom` line still
# parses for back-compat.)
if grep -qE 'EDGE_BOTTOM|panel_bottom' "$PANEL" \
        && grep -q '"position"' "$PANEL" \
        && grep -q '"bottom"' "$PANEL"; then
    passed "hampanelscene parses the panel position/edge (top/bottom)"
else
    failed "hampanelscene does not parse the position/edge line"
fi

# Guard against the old dead-ignore comment regressing back in.
if grep -q 'position ...` line: ignored' "$PANEL"; then
    failed "hampanelscene still IGNORES the position line"
else
    passed "hampanelscene no longer ignores the position line"
fi

# --- 1b. The panel places the window at the chosen edge ---------------
if grep -q '_apply_panel_geometry' "$PANEL" \
        && grep -q '_screen_height' "$PANEL"; then
    passed "hampanelscene positions the panel window per edge (uses screen height)"
else
    failed "hampanelscene missing edge-aware geometry placement"
fi

# --- 1c + 2. Live config re-read so Settings changes apply ------------
if grep -q '_cfg_changed' "$PANEL"; then
    passed "hampanelscene live-reloads /etc/panel.conf (position + sysmon apply)"
else
    failed "hampanelscene does NOT live-reload the config (changes need a restart)"
fi

# The sysmon applet word must still be a recognized config applet.
if grep -q '"sysmon"' "$PANEL"; then
    passed "hampanelscene recognizes the sysmon applet config word"
else
    failed "hampanelscene dropped the sysmon applet recognition"
fi

# --- 3. execve stamps the running program name into /proc/tasks -------
if grep -q 'def set_task_name0_from_path' "$CORE"; then
    passed "core.ad provides set_task_name0_from_path (name0/comm from basename)"
else
    failed "core.ad missing the execve name0/comm stamp helper"
fi
if grep -q 'set_task_name0_from_path' "$SYSCALL"; then
    passed "do_execve stamps the program basename (proc list shows real names)"
else
    failed "do_execve does NOT stamp the program name (proc list stays '__rfork_')"
fi

# --- 4. Compile the touched user app clean ----------------------------
out="$(mktemp --tmpdir "hamnix-hampanelscene.XXXXXX.elf")"
if python3 -m compiler.adder compile --target=x86_64-adder-user \
        "$PANEL" -o "$out" >/tmp/panel_prefs.compile.log 2>&1 \
        && file "$out" | grep -q ELF; then
    passed "hampanelscene compiles to an ELF"
else
    failed "hampanelscene did NOT compile (see /tmp/panel_prefs.compile.log)"
    tail -8 /tmp/panel_prefs.compile.log >&2 || true
fi
rm -f "$out"

if [ "$fail" = "0" ]; then
    echo "[panel_prefs] RESULT: PASS"
    exit 0
fi
echo "[panel_prefs] RESULT: FAIL" >&2
exit 1
