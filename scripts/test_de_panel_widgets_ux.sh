#!/usr/bin/env bash
# scripts/test_de_panel_widgets_ux.sh — static guards for the DE panel /
# settings UX fixes (from a real hands-on session) so they don't silently
# regress. Cheap grep/compile assertions only — no QEMU. The live proofs are
# the KVM DE drivers + screendumps.
#
#   A1  WINDOW LIST tracks live windows: hampanelscene enumerates
#       /dev/wsys/windows, hashes the snapshot (FNV-1a) so ANY change (open /
#       close / title-late / same-count swap) repaints the taskbar.
#   A2  CPU widget reports real utilisation via an idle/total DELTA from
#       /dev/uptime (NOT the load-average*50 scaling that pegged at 100%);
#       the first sample has no baseline so it reports 0%, not "all busy".
#   A3  Right-click on BLANK bar space (incl. the elastic tasks/spacer region)
#       opens the ADD-A-WIDGET menu, not Move/Remove.
#   A4  Right-click on a real widget INCLUDING the Applications button opens the
#       per-widget Move / Remove menu.
#   A5  hamsettings: edge selector keeps all four panels on DISTINCT edges; the
#       Add-widget chips live in their own sub-column (no overlap with
#       Up/Down/Del).
#   A6  The Applications dropdown lists the Web Browser (/bin/hambrowse) and the
#       file manager (Files).
set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

fail=0
pass() { echo "[panel_ux] PASS $1"; }
failf() { echo "[panel_ux] FAIL $1" >&2; fail=1; }
need() { grep -q -- "$2" "$1" && pass "$3" || failf "$3"; }

PS="user/hampanelscene.ad"; SET="user/hamsettings.ad"

echo "[panel_ux] --- A1: live window-list ---"
need "$PS" '"/dev/wsys/windows"' "panel enumerates /dev/wsys/windows"
need "$PS" "win_hash" "panel hashes the window snapshot for change-detect"
need "$PS" "if win_hash != last_win_hash" "panel repaints when the window set changes"
need "$PS" "def _render_tasks" "panel renders the window-list taskbar"

echo "[panel_ux] --- A2: CPU widget idle/total delta ---"
need "$PS" '"/dev/uptime"' "CPU widget samples /dev/uptime (idle+total)"
need "$PS" "_cpu_prev_total" "CPU widget keeps a previous-sample baseline"
need "$PS" "_cpu_inited" "CPU widget has a first-sample guard"
if grep -q 'pct: uint64 = centi / 2' "$PS"; then
    failf "CPU widget still scales load-average (centi/2) — pegs at 100%"
else
    pass "CPU widget no longer uses the load-average*50 scaling"
fi

echo "[panel_ux] --- A3/A4: right-click context routing ---"
need "$PS" "if wsk == WK_TASKS or wsk == WK_SPACER:" "elastic tasks/spacer counts as blank space (Add menu)"
# The Apps/menu widget must NOT special-case into the CTXK_APPMENU shortcut in
# the right-click dispatch (it now uses the shared Move/Remove menu).
disp="$(awk '/def _handle_button/,/def _ctx_select_row/' "$PS")"
if grep -q "ctx_kind = CTXK_APPMENU" <<<"$disp"; then
    failf "right-click dispatch still routes the Apps widget to CTXK_APPMENU (should be Move/Remove)"
else
    pass "right-click on any widget (incl. Apps) opens Move/Remove"
fi

echo "[panel_ux] --- A5: settings edge distinctness + no overlap ---"
need "$SET" "Keep every panel on a DISTINCT edge" "edge selector keeps panels on distinct edges"
need "$SET" "WADD_X" "add-widget chips live in their own sub-column"
if grep -q 'bx: int32 = WACT_X + k \* 48' "$SET"; then
    failf "add-widget chips still start at WACT_X (overlap Up/Down/Del)"
else
    pass "add-widget chips no longer overlap the Up/Down/Del stack"
fi

echo "[panel_ux] --- A6: browser + files in the Applications menu ---"
need "$PS" '"/bin/hambrowse"' "Applications menu launches the Web Browser"
need "$PS" '"Web Browser"' "Applications menu shows a Web Browser row"
need "$PS" '"/bin/hamfmscene"' "Applications menu launches the file manager"

echo "[panel_ux] --- compile the touched user binaries ---"
# shellcheck source=_adder_cc.sh
source "$PROJ_ROOT/scripts/_adder_cc.sh"
mkdir -p build/user
for n in hampanelscene hamsettings; do
    if adder_cc_compile compile --target=x86_64-adder-user "user/${n}.ad" \
            -o "build/user/${n}.elf" >/dev/null 2>&1; then
        pass "user/${n}.ad compiles"
    else
        failf "user/${n}.ad failed to compile"
    fi
done

echo "[panel_ux] --- result ---"
if [ "$fail" = 0 ]; then echo "[panel_ux] RESULT: PASS"; exit 0
else echo "[panel_ux] RESULT: FAIL"; exit 1; fi
