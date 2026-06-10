#!/usr/bin/env bash
# scripts/test_hamUI_cursorcol.sh — acceptance gate for the terminal cursor
# COLUMN-tracking fix in the hamUId compositor.
#
# User report: in a DE terminal window the text-input cursor (the black
# square) was drawn on the correct ROW but always at COLUMN 0, never at the
# real input column. Root cause: hamsh's line editor repaints the line by
# emitting CR (carriage return -> column 0), re-emitting the prompt + buffer,
# then parking the cursor with ESC[<n>C (cursor-forward). The hamUId terminal
# emulator (term_feed) used to SWALLOW every CSI escape sequence, so the
# ESC[<n>C park was dropped and the cursor stayed at column 0.
#
# The fix teaches term_feed the cursor-positioning CSI sequences
# (CUU/CUD/CUF/CUB/CHA/VPA/CUP and EL). This test drives the EXACT byte
# stream hamsh's _ed_redraw produces and asserts the cursor lands at the
# right cell — and that the rendered cursor BLOCK is drawn at that column,
# not at column 0.
#
# The proof is a DETERMINISTIC serial self-test driven through the daemon's
# own sub-command (no QEMU mouse/key injection):
#   - hamUId daemon decursor -> "[DECURSOR] ..." OK lines + "[DECURSOR] PASS"
#
# Like the other -vga std hamUI self-tests this SKIPS CLEANLY (exit 0) when
# the daemon can't bring up a framebuffer under QEMU multiboot/VBE on this
# host; the authoritative GOP render gate is scripts/test_img_uefi_hamui.sh.

. "$(dirname "$0")/_build_lock.sh"

set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf

echo "[test_hamUI_cursorcol] (1/4) Build userland"
bash scripts/build_user.sh >/dev/null
bash scripts/build_modules.sh >/dev/null

echo "[test_hamUI_cursorcol] (2/4) Build initramfs"
python3 scripts/build_initramfs.py >/dev/null

echo "[test_hamUI_cursorcol] (3/4) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

if [ ! -s build/user/hamUId.elf ]; then
    echo "[test_hamUI_cursorcol] FAIL: build/user/hamUId.elf missing/empty"
    exit 1
fi

echo "[test_hamUI_cursorcol] (4/4) Boot QEMU + run the cursor-column self-test"

LOG="$(mktemp)"
FIFO="$(mktemp -u).in"
mkfifo "$FIFO"
trap 'rm -f "$LOG" "$FIFO"' EXIT

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
exec 3>"$FIFO"

if wait_for 'hamsh\$' 90; then
    send_selftest 'echo MARK_DECURSOR_BEGIN; hamUId daemon decursor' '\[DECURSOR\] (PASS|FAIL)' 60 3
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

if grep -aE -q "PANIC|panic:|TRAP:|BUG:" "$LOG"; then
    echo "[test_hamUI_cursorcol] FAIL: kernel panic / trap"
    tail -n 60 "$LOG"
    exit 1
fi

if ! grep -aq 'DAEMON up screen=' "$LOG"; then
    echo "[test_hamUI_cursorcol] SKIP: hamUId daemon did not come up under -vga std on this host (QEMU multiboot VBE+64-bit limitation). Authoritative GOP gate: scripts/test_img_uefi_hamui.sh." >&2
    exit 0
fi

echo "[test_hamUI_cursorcol] --- captured serial markers ---"
grep -aE 'DAEMON up|\[DECURSOR\]|MARK_' "$LOG" | head -80
echo "[test_hamUI_cursorcol] --- end ---"

fail=0

assert_marker() {
    if grep -aq "$1" "$LOG"; then
        echo "[test_hamUI_cursorcol] OK: $2"
    else
        echo "[test_hamUI_cursorcol] MISS: $2 (expected marker: '$1')"
        fail=1
    fi
}

assert_marker '\[DECURSOR\] ESC\[<n>C parks the caret at the real column OK' '1: CR + ESC[<n>C (hamsh _ed_redraw) lands the cursor at the real column, not 0'
assert_marker '\[DECURSOR\] CUP ESC\[3;5H lands at the absolute cell OK' '2: ESC[3;5H sets the absolute (row,col)'
assert_marker '\[DECURSOR\] CHA ESC\[12G sets the absolute column OK' '3: ESC[12G sets the absolute column on the current row'
assert_marker '\[DECURSOR\] cursor block renders at the tracked column, not col 0 OK' '4: window_render_self draws the dark cursor block at the tracked column'
assert_marker '\[DECURSOR\] PASS' 'DECURSOR: cursor-column self-test ran to completion'

if grep -aqE '\[DECURSOR\] FAIL' "$LOG"; then
    echo "[test_hamUI_cursorcol] FAIL: the self-test reported a failure:"
    grep -aE '\[DECURSOR\] FAIL' "$LOG" | head
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_hamUI_cursorcol] FAIL (qemu rc=$rc)"
    exit 1
fi

echo "[test_hamUI_cursorcol] capture method: drives the real 'hamUId daemon decursor' self-test over serial; deterministic [DECURSOR] markers, no QEMU mouse/key injection"
echo "[test_hamUI_cursorcol] PASS"
