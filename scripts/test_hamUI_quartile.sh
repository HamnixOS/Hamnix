#!/usr/bin/env bash
# scripts/test_hamUI_quartile.sh — acceptance gate for MATE/Marco-parity
# CORNER-QUADRANT WINDOW TILING in the in-compositor desktop environment:
#
#   QUARTER / CORNER-QUADRANT TILING (Marco-style): dragging a window's title
#   bar so the pointer reaches a screen CORNER snaps the window to exactly the
#   top-left / top-right / bottom-left / bottom-right QUARTER of the work area
#   (the panel-aware desktop region below/above the MATE panel). The four
#   quadrants tile the work area with NO gap and NO overlap: the two left
#   quadrants share x=0, the two right quadrants share x=scr_w/2 (and their
#   widths sum to scr_w), the top pair shares y=work_top and the bottom pair
#   starts at work_top+work_h/2 (with heights summing to work_h). The keyboard
#   tile_focused path snaps the FRONT-most window to a quadrant, and un-snap
#   restores the EXACT pre-snap float rect. Driven through snap_zone_for /
#   snap_apply / tile_focused — the SAME functions the live mouse-drag and
#   keyboard tiling state machines use.
#
# The proof is a DETERMINISTIC serial self-test driven through the daemon's
# own sub-command (no QEMU mouse/key injection):
#   - hamUId daemon dequartile -> "[DEQT] ..." OK lines + "[DEQT] PASS"/"FAIL"
#     Every assertion is pure model state run through the SAME functions the
#     live DE uses, so it runs with NO real framebuffer under -serial stdio.
#
# Like the other -vga std hamUI self-tests this SKIPS CLEANLY (exit 0) when
# the daemon can't bring up a framebuffer under QEMU multiboot/VBE on this
# host; the authoritative GOP render gate is scripts/test_img_uefi_hamui.sh.

. "$(dirname "$0")/_build_lock.sh"

set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf

echo "[test_hamUI_quartile] (1/4) Build userland"
bash scripts/build_user.sh >/dev/null
bash scripts/build_modules.sh >/dev/null

echo "[test_hamUI_quartile] (2/4) Build initramfs"
python3 scripts/build_initramfs.py >/dev/null

echo "[test_hamUI_quartile] (3/4) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

if [ ! -s build/user/hamUId.elf ]; then
    echo "[test_hamUI_quartile] FAIL: build/user/hamUId.elf missing/empty"
    exit 1
fi

echo "[test_hamUI_quartile] (4/4) Boot QEMU + run the DE corner-quadrant tiling self-test"

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
    # DEQT corner-quadrant tiling proof. RE-SEND until the [DEQT] marker lands
    # (the freshly-booted shell drops the first serial command line).
    send_selftest 'echo MARK_DEQT_BEGIN; hamUId daemon dequartile' '\[DEQT\] (PASS|FAIL)' 60 3
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
    echo "[test_hamUI_quartile] FAIL: kernel panic / trap"
    tail -n 60 "$LOG"
    exit 1
fi

# SKIP CLEANLY when the hamUId daemon never came up under -vga std on this
# host (QEMU multiboot1 VBE + 64-bit ELF limitation). Authoritative GOP
# gate: scripts/test_img_uefi_hamui.sh.
if ! grep -aq 'DAEMON up screen=' "$LOG"; then
    echo "[test_hamUI_quartile] SKIP: hamUId daemon did not come up under -vga std on this host (QEMU multiboot VBE+64-bit limitation). Authoritative GOP gate: scripts/test_img_uefi_hamui.sh." >&2
    exit 0
fi

echo "[test_hamUI_quartile] --- captured serial markers ---"
grep -aE 'DAEMON up|\[DEQT\]|MARK_' "$LOG" | head -80
echo "[test_hamUI_quartile] --- end ---"

fail=0

assert_marker() {
    if grep -aq "$1" "$LOG"; then
        echo "[test_hamUI_quartile] OK: $2"
    else
        echo "[test_hamUI_quartile] MISS: $2 (expected marker: '$1')"
        fail=1
    fi
}

# --- 1. the four corner quadrants ----------------------------------------
assert_marker '\[DEQT\] top-left corner tiles to the top-left quarter OK' '1a: a corner-reaching drag at the TOP-LEFT classifies + tiles to the top-left quarter of the work area'
assert_marker '\[DEQT\] top-left snap / un-snap round-trips the exact float rect OK' '1b: un-snapping a top-left quarter restores the EXACT pre-snap float rect'
assert_marker '\[DEQT\] top-right corner tiles to the top-right quarter OK' '1c: a corner-reaching drag at the TOP-RIGHT tiles to the top-right quarter'
assert_marker '\[DEQT\] bottom-left corner tiles to the bottom-left quarter OK' '1d: a corner-reaching drag at the BOTTOM-LEFT tiles to the bottom-left quarter'
assert_marker '\[DEQT\] bottom-right corner tiles to the bottom-right quarter OK' '1e: a corner-reaching drag at the BOTTOM-RIGHT tiles to the bottom-right quarter'

# --- 2. the four quadrants tile the work area ----------------------------
assert_marker '\[DEQT\] the four quadrants tile the work area with no gap or overlap OK' '2a: the four quadrants paper the panel-aware work area with no gap and no overlap'

# --- 3. keyboard quarter-tile + un-snap ----------------------------------
assert_marker '\[DEQT\] keyboard quarter-tile snaps the focused window to a quadrant OK' '3a: the keyboard tile_focused path snaps the FRONT-most window to a quadrant'
assert_marker '\[DEQT\] keyboard quarter-tile un-snap restores the exact float rect OK' '3b: un-snapping the keyboard-tiled window restores the EXACT float rect'

assert_marker '\[DEQT\] PASS' 'DEQT: corner-quadrant tiling self-test ran to completion'

# Any explicit FAIL marker from the self-test is a hard failure.
if grep -aqE '\[DEQT\] FAIL' "$LOG"; then
    echo "[test_hamUI_quartile] FAIL: the self-test reported a failure:"
    grep -aE '\[DEQT\] FAIL' "$LOG" | head
    fail=1
fi

# The serial markers are the source of truth, not the qemu exit code (the
# feeder tears qemu down with a signal once the last marker lands, so a
# nonzero rc here is expected and ignored).
if [ "$fail" -ne 0 ]; then
    echo "[test_hamUI_quartile] FAIL (qemu rc=$rc)"
    exit 1
fi

echo "[test_hamUI_quartile] capture method: drives the real 'hamUId daemon dequartile' self-test over serial; deterministic [DEQT] markers, no QEMU mouse/key injection"
echo "[test_hamUI_quartile] PASS"
