#!/usr/bin/env bash
# scripts/test_hamUI_resize.sh — acceptance gate for the two MATE/Marco-parity
# WINDOW-MANAGEMENT features added to the in-compositor desktop environment:
#
#   1. Window EDGE / CORNER RESIZE-DRAG (Marco-style): pressing a window's
#      border or corner (outside the title-bar move zone) and dragging resizes
#      the window. The right border (+40px) widens by exactly 40 with x/y/top
#      unchanged; the bottom-left corner changes BOTH width and height (and x)
#      at once; an inward drag clamps at the minimum window size, never
#      smaller. Driven through resize_dir_at / resize_begin / resize_track /
#      resize_end — the SAME functions the live mouse-drag state machine uses.
#   2. SHOW-DESKTOP / MINIMIZE-ALL TOGGLE (MATE panel applet + F10 / Super-D):
#      the first invocation hides EVERY visible window on the current workspace
#      so the composite/visible set becomes empty; the second invocation
#      restores EXACTLY that set (same slots visible, same focus). Driven
#      through show_desktop_toggle() — the SAME function the panel
#      Show-Desktop button and the F10 key route to.
#
# The proof is a DETERMINISTIC serial self-test driven through the daemon's
# own sub-command (no QEMU mouse/key injection):
#   - hamUId daemon deresize -> "[DERS] ..." OK lines + "[DERS] PASS"/"FAIL"
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

echo "[test_hamUI_resize] (1/4) Build userland"
bash scripts/build_user.sh >/dev/null
bash scripts/build_modules.sh >/dev/null

echo "[test_hamUI_resize] (2/4) Build initramfs"
python3 scripts/build_initramfs.py >/dev/null

echo "[test_hamUI_resize] (3/4) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

if [ ! -s build/user/hamUId.elf ]; then
    echo "[test_hamUI_resize] FAIL: build/user/hamUId.elf missing/empty"
    exit 1
fi

echo "[test_hamUI_resize] (4/4) Boot QEMU + run the DE resize/show-desktop self-test"

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
    # DERS resize / show-desktop proof. RE-SEND until the [DERS] marker lands
    # (the freshly-booted shell drops the first serial command line).
    send_selftest 'echo MARK_DERS_BEGIN; hamUId daemon deresize' '\[DERS\] (PASS|FAIL)' 60 3
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
    echo "[test_hamUI_resize] FAIL: kernel panic / trap"
    tail -n 60 "$LOG"
    exit 1
fi

# SKIP CLEANLY when the hamUId daemon never came up under -vga std on this
# host (QEMU multiboot1 VBE + 64-bit ELF limitation). Authoritative GOP
# gate: scripts/test_img_uefi_hamui.sh.
if ! grep -aq 'DAEMON up screen=' "$LOG"; then
    echo "[test_hamUI_resize] SKIP: hamUId daemon did not come up under -vga std on this host (QEMU multiboot VBE+64-bit limitation). Authoritative GOP gate: scripts/test_img_uefi_hamui.sh." >&2
    exit 0
fi

echo "[test_hamUI_resize] --- captured serial markers ---"
grep -aE 'DAEMON up|\[DERS\]|MARK_' "$LOG" | head -80
echo "[test_hamUI_resize] --- end ---"

fail=0

assert_marker() {
    if grep -aq "$1" "$LOG"; then
        echo "[test_hamUI_resize] OK: $2"
    else
        echo "[test_hamUI_resize] MISS: $2 (expected marker: '$1')"
        fail=1
    fi
}

# --- 1. edge/corner resize-drag ------------------------------------------
assert_marker '\[DERS\] right-border press classifies as the right-edge grip OK' '1a: a press on the right border hit-tests to the right-edge resize grip'
assert_marker '\[DERS\] right-border +40 drag widens by 40, x/y/top/height unchanged OK' '1b: dragging the right border +40px widens by exactly 40, leaving x/y/top/height unchanged'
assert_marker '\[DERS\] bottom-left corner classifies as the left+bottom grip OK' '1c: a press on the bottom-left corner hit-tests to the left+bottom grip (mask 9)'
assert_marker '\[DERS\] bottom-left corner drag changes width+height (and x) together OK' '1d: dragging the bottom-left corner changes BOTH width and height (and x) correctly'
assert_marker '\[DERS\] resize clamps at the minimum size, never smaller OK' '1e: dragging a border inward past the minimum clamps at exactly the min dimension, not smaller'

# --- 2. show-desktop / minimize-all toggle -------------------------------
assert_marker '\[DERS\] Show-Desktop hides all current-workspace windows (composite set empty) OK' '2a: Show-Desktop hides ALL current-workspace windows (composite/visible set becomes empty)'
assert_marker '\[DERS\] Show-Desktop second toggle restores exactly the previously-visible set + focus OK' '2b: a second toggle restores EXACTLY the previously-visible set (same slots, same focus)'

assert_marker '\[DERS\] PASS' 'DERS: resize / show-desktop self-test ran to completion'

# Any explicit FAIL marker from the self-test is a hard failure.
if grep -aqE '\[DERS\] FAIL' "$LOG"; then
    echo "[test_hamUI_resize] FAIL: the self-test reported a failure:"
    grep -aE '\[DERS\] FAIL' "$LOG" | head
    fail=1
fi

# The serial markers are the source of truth, not the qemu exit code (the
# feeder tears qemu down with a signal once the last marker lands, so a
# nonzero rc here is expected and ignored).
if [ "$fail" -ne 0 ]; then
    echo "[test_hamUI_resize] FAIL (qemu rc=$rc)"
    exit 1
fi

echo "[test_hamUI_resize] capture method: drives the real 'hamUId daemon deresize' self-test over serial; deterministic [DERS] markers, no QEMU mouse/key injection"
echo "[test_hamUI_resize] PASS"
