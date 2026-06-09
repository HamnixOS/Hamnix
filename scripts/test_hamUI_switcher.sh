#!/usr/bin/env bash
# scripts/test_hamUI_switcher.sh — acceptance gate for the MATE/Marco-parity
# Alt-Tab WINDOW SWITCHER + DESKTOP RIGHT-CLICK MENU added to the in-
# compositor desktop environment:
#
#   1. ALT-TAB MRU SWITCHER (Marco style): holding Alt and pressing Tab cycles
#      forward through the window stack in MOST-RECENTLY-USED order; the first
#      Tab from a 3-window stack selects the 2nd MRU window, a second Tab the
#      3rd; releasing Alt raises+focuses the selected window and moves it to
#      the MRU front. Shift-Tab cycles backward. A window on another workspace
#      (or minimized) is NOT a candidate.
#   2. DESKTOP RIGHT-CLICK CONTEXT MENU: right-clicking the root/desktop
#      background pops a menu (Open Terminal / Open File Manager / New
#      Workspace / ...). The box width fits its widest label (no clipping,
#      reusing ctx_menu_width), and selecting "Open Terminal" spawns the in-
#      compositor APP_TERM window.
#
# The proof is a DETERMINISTIC serial self-test driven through the daemon's
# own sub-command (no QEMU mouse/key injection):
#   - hamUId daemon deswitch -> "[DESW] ..." OK lines + "[DESW] PASS"/"[DESW]
#     FAIL". Every assertion is pure model state run through the SAME functions
#     the live DE uses (cycle_step/cycle_commit over mru_slot_for_pos +
#     mru_touch, win_on_cur_ws/window_to_workspace for workspace filtering,
#     ctx_open_at/ctx_menu_width + ctx_invoke + daemon_spawn_app), so it runs
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

echo "[test_hamUI_switcher] (1/4) Build userland"
bash scripts/build_user.sh >/dev/null
bash scripts/build_modules.sh >/dev/null

echo "[test_hamUI_switcher] (2/4) Build initramfs"
python3 scripts/build_initramfs.py >/dev/null

echo "[test_hamUI_switcher] (3/4) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

if [ ! -s build/user/hamUId.elf ]; then
    echo "[test_hamUI_switcher] FAIL: build/user/hamUId.elf missing/empty"
    exit 1
fi

echo "[test_hamUI_switcher] (4/4) Boot QEMU + run the DE switcher/menu self-test"

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
    # DESW switcher/menu proof. RE-SEND until the [DESW] marker lands (the
    # freshly-booted shell drops the first serial command line).
    send_selftest 'echo MARK_DESW_BEGIN; hamUId daemon deswitch' '\[DESW\] (PASS|FAIL)' 60 3
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
    echo "[test_hamUI_switcher] FAIL: kernel panic / trap"
    tail -n 60 "$LOG"
    exit 1
fi

# SKIP CLEANLY when the hamUId daemon never came up under -vga std on this
# host (QEMU multiboot1 VBE + 64-bit ELF limitation). Authoritative GOP
# gate: scripts/test_img_uefi_hamui.sh.
if ! grep -aq 'DAEMON up screen=' "$LOG"; then
    echo "[test_hamUI_switcher] SKIP: hamUId daemon did not come up under -vga std on this host (QEMU multiboot VBE+64-bit limitation). Authoritative GOP gate: scripts/test_img_uefi_hamui.sh." >&2
    exit 0
fi

echo "[test_hamUI_switcher] --- captured serial markers ---"
grep -aE 'DAEMON up|\[DESW\]|MARK_' "$LOG" | head -80
echo "[test_hamUI_switcher] --- end ---"

fail=0

assert_marker() {
    if grep -aq "$1" "$LOG"; then
        echo "[test_hamUI_switcher] OK: $2"
    else
        echo "[test_hamUI_switcher] MISS: $2 (expected marker: '$1')"
        fail=1
    fi
}

# --- 1. Alt-Tab MRU switcher ---------------------------------------------
assert_marker '\[DESW\] MRU order tracks focus changes OK' '1: the MRU order updates on every focus change'
assert_marker '\[DESW\] Alt-Tab from a 3-window stack selects the 2nd MRU window OK' '1: the first Alt-Tab from a 3-window stack selects the 2nd MRU window'
assert_marker '\[DESW\] a second Tab selects the 3rd MRU window OK' '1: a second Tab advances to the 3rd MRU window'
assert_marker '\[DESW\] releasing Alt raises+focuses the selection and fronts the MRU OK' '1: releasing Alt raises+focuses the selected window and fronts it in the MRU'

# --- 2. Shift-Tab reverses direction -------------------------------------
assert_marker '\[DESW\] Shift-Tab reverses the cycle direction OK' '2: Shift-Tab cycles backward (reverses the forward Tab selection)'

# --- 3. off-workspace windows are not candidates -------------------------
assert_marker '\[DESW\] a window on another workspace is NOT an Alt-Tab candidate OK' '3: a window moved to another workspace is excluded from the Alt-Tab candidate list'

# --- 4. desktop right-click context menu ---------------------------------
assert_marker '\[DESW\] desktop context menu box fits its widest label OK' '4: the desktop right-click menu box width fits its widest label (ctx_menu_width)'
assert_marker '\[DESW\] desktop menu Open Terminal spawns an APP_TERM window OK' '4: selecting Open Terminal spawns an in-compositor APP_TERM window'

assert_marker '\[DESW\] PASS' 'DESW: switcher/menu self-test ran to completion'

# Any explicit FAIL marker from the self-test is a hard failure.
if grep -aqE '\[DESW\] FAIL' "$LOG"; then
    echo "[test_hamUI_switcher] FAIL: the self-test reported a failure:"
    grep -aE '\[DESW\] FAIL' "$LOG" | head
    fail=1
fi

# The serial markers are the source of truth, not the qemu exit code (the
# feeder tears qemu down with a signal once the last marker lands, so a
# nonzero rc here is expected and ignored).
if [ "$fail" -ne 0 ]; then
    echo "[test_hamUI_switcher] FAIL (qemu rc=$rc)"
    exit 1
fi

echo "[test_hamUI_switcher] capture method: drives the real 'hamUId daemon deswitch' self-test over serial; deterministic [DESW] markers, no QEMU mouse/key injection"
echo "[test_hamUI_switcher] PASS"
