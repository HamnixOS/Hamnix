#!/usr/bin/env bash
# scripts/test_hamUI_wm.sh — acceptance gate for the MATE/Marco-parity
# WINDOW MANAGEMENT added to the in-compositor desktop environment:
#
#   1. Window MAXIMIZE / RESTORE: a double-click on the title bar (or the
#      maximize titlebar button) toggles a window between its floating
#      geometry and the full work area (screen minus the panel). The pre-
#      maximize rect is remembered EXACTLY and a second toggle restores it.
#   2. Window SNAPPING (Marco-style edge tiling): a move-drag whose pointer
#      reaches the LEFT screen edge snaps the window to the left half of the
#      work area; the pre-snap geometry is remembered so dragging away
#      un-snaps to the EXACT float rect.
#   3. MINIMIZE to panel + restore: the minimize box hides the window so it
#      leaves the composite/visible set, while a panel window-list (taskbar)
#      entry still lists it; clicking that entry restores + raises + focuses.
#   4. WORKSPACES / virtual desktops (MATE pager): a window on workspace 2
#      does NOT composite while workspace 1 is current and DOES after
#      switching to workspace 2 (driven by the Ctrl-Alt-Right keyboard path).
#
# The proof is a DETERMINISTIC serial self-test driven through the daemon's
# own sub-command (no QEMU mouse/key injection):
#   - hamUId daemon dewm -> "[DEWM] ..." OK lines + "[DEWM] PASS"/"[DEWM] FAIL"
#     Every assertion is pure model state run through the SAME functions the
#     live DE uses (window_toggle_maximize, snap_zone_for/snap_apply,
#     DWIN_HIDDEN + taskbar_lists_slot/taskbar_slot_at + daemon_raise_slot,
#     win_on_cur_ws gated by workspace_switch/window_to_workspace), so it runs
#     with NO real framebuffer under -serial stdio.
#
# Like the other -vga std hamUI self-tests this SKIPS CLEANLY (exit 0) when
# the daemon can't bring up a framebuffer under QEMU multiboot/VBE on this
# host; the authoritative GOP render gate is scripts/test_img_uefi_hamui.sh.

. "$(dirname "$0")/_build_lock.sh"

set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf

echo "[test_hamUI_wm] (1/4) Build userland"
bash scripts/build_user.sh >/dev/null
bash scripts/build_modules.sh >/dev/null

echo "[test_hamUI_wm] (2/4) Build initramfs"
python3 scripts/build_initramfs.py >/dev/null

echo "[test_hamUI_wm] (3/4) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

if [ ! -s build/user/hamUId.elf ]; then
    echo "[test_hamUI_wm] FAIL: build/user/hamUId.elf missing/empty"
    exit 1
fi

echo "[test_hamUI_wm] (4/4) Boot QEMU + run the DE window-management self-test"

LOG="$(mktemp)"
FIFO="$(mktemp -u).in"
mkfifo "$FIFO"
trap 'rm -f "$LOG" "$FIFO"' EXIT

# Robust feeder. Two boot realities forced this design:
#   1) Gate on serial markers, never wall-clock — a blind `sleep N` raced
#      boot under -vga std + SMP TCG.
#   2) The freshly-booted shell is not yet draining the serial console when
#      its first prompt prints, so the FIRST command line sent is dropped at
#      the input layer (its characters never even echo). So each self-test is
#      RE-SENT until its own terminal marker appears; the first try priming
#      the console, a later try landing once the shell reads.
wait_for() {  # $1=ERE marker  $2=timeout secs ; returns 0 if seen
    local deadline=$(( SECONDS + $2 ))
    while [ "$SECONDS" -lt "$deadline" ]; do
        grep -aqE "$1" "$LOG" && return 0
        kill -0 "$QEMU_PID" 2>/dev/null || return 1
        sleep 1
    done
    return 1
}

send_selftest() {  # $1=shell line  $2=terminal-marker ERE  $3=secs/try  $4=tries
    local t=0
    while [ "$t" -lt "$4" ]; do
        printf '%s\n' "$1" >&3
        wait_for "$2" "$3" && return 0
        t=$(( t + 1 ))
    done
    return 1
}

set +e
qemu-system-x86_64 \
    -kernel "$ELF" \
    -smp 2 \
    -vga std \
    -display none \
    -no-reboot \
    -m 256M \
    -serial stdio \
    < "$FIFO" > "$LOG" 2>&1 &
QEMU_PID=$!
# Hold the FIFO open for writing so qemu's stdin never sees EOF mid-run.
exec 3>"$FIFO"

if wait_for 'hamsh\$' 90; then
    # DEWM window-management proof. RE-SEND until the [DEWM] marker lands
    # (the freshly-booted shell drops the first serial command line).
    send_selftest 'echo MARK_DEWM_BEGIN; hamUId daemon dewm' '\[DEWM\] (PASS|FAIL)' 60 3
fi

exec 3>&-
sleep 1
kill "$QEMU_PID" 2>/dev/null
( sleep 4; kill -9 "$QEMU_PID" 2>/dev/null ) &
WD=$!
wait "$QEMU_PID" 2>/dev/null
rc=$?
kill "$WD" 2>/dev/null
set -e

# A kernel panic / CPU trap is ALWAYS a hard failure.
if grep -aE -q "PANIC|panic:|TRAP:|BUG:" "$LOG"; then
    echo "[test_hamUI_wm] FAIL: kernel panic / trap"
    tail -n 60 "$LOG"
    exit 1
fi

# SKIP CLEANLY when the hamUId daemon never came up under -vga std on this
# host (QEMU multiboot1 VBE + 64-bit ELF limitation). Authoritative GOP
# gate: scripts/test_img_uefi_hamui.sh.
if ! grep -aq 'DAEMON up screen=' "$LOG"; then
    echo "[test_hamUI_wm] SKIP: hamUId daemon did not come up under -vga std on this host (QEMU multiboot VBE+64-bit limitation). Authoritative GOP gate: scripts/test_img_uefi_hamui.sh." >&2
    exit 0
fi

echo "[test_hamUI_wm] --- captured serial markers ---"
grep -aE 'DAEMON up|\[DEWM\]|MARK_' "$LOG" | head -80
echo "[test_hamUI_wm] --- end ---"

fail=0

assert_marker() {
    if grep -aq "$1" "$LOG"; then
        echo "[test_hamUI_wm] OK: $2"
    else
        echo "[test_hamUI_wm] MISS: $2 (expected marker: '$1')"
        fail=1
    fi
}

# --- 1. maximize / restore -----------------------------------------------
assert_marker '\[DEWM\] maximize fills the work area OK' '1: maximize sets the rect to the full work area (screen minus panel)'
assert_marker '\[DEWM\] maximize/restore round-trips the exact original rect OK' '1: restore returns the EXACT pre-maximize rect'

# --- 2. left-edge snap / un-snap -----------------------------------------
assert_marker '\[DEWM\] left-edge snap tiles to the left half OK' '2: left screen edge snaps the window to the left half of the work area'
assert_marker '\[DEWM\] left snap / un-snap round-trips the exact rect OK' '2: un-snap restores the EXACT pre-snap float rect'

# --- 3. minimize to panel + restore --------------------------------------
assert_marker '\[DEWM\] minimize hides from composite + panel window-list entry remains OK' '3: minimize removes the window from the composite set; the panel window-list entry remains'
assert_marker '\[DEWM\] panel window-list restore brings the window back focused OK' '3: clicking the window-list entry restores + raises + focuses the window'

# --- 4. workspaces / virtual desktops ------------------------------------
assert_marker '\[DEWM\] window on workspace 2 is NOT composited on workspace 1 OK' '4: a window on workspace 2 does NOT composite while workspace 1 is current'
assert_marker '\[DEWM\] workspace switch composites ws-2 window and hides ws-1 windows OK' '4: switching to workspace 2 (Ctrl-Alt-Right) composites its window and hides workspace-1 windows'

assert_marker '\[DEWM\] PASS' 'DEWM: window-management self-test ran to completion'

# Any explicit FAIL marker from the self-test is a hard failure.
if grep -aqE '\[DEWM\] FAIL' "$LOG"; then
    echo "[test_hamUI_wm] FAIL: the self-test reported a failure:"
    grep -aE '\[DEWM\] FAIL' "$LOG" | head
    fail=1
fi

# The serial markers are the source of truth, not the qemu exit code (the
# feeder tears qemu down with a signal once the last marker lands, so a
# nonzero rc here is expected and ignored).
if [ "$fail" -ne 0 ]; then
    echo "[test_hamUI_wm] FAIL (qemu rc=$rc)"
    exit 1
fi

echo "[test_hamUI_wm] capture method: drives the real 'hamUId daemon dewm' self-test over serial; deterministic [DEWM] markers, no QEMU mouse/key injection"
echo "[test_hamUI_wm] PASS"
