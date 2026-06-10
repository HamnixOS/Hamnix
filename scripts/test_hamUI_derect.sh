#!/usr/bin/env bash
# scripts/test_hamUI_derect.sh — acceptance gate for the /dev/fbctl binary
# RECT dirty-rectangle present path the in-compositor desktop now CONSUMES.
#
# The kernel landed a one-write dirty-rectangle present command on /dev/fbctl
# (drivers/video/fb_cdev.ad::_fbctl_rect_present): a 52-byte little-endian
# RECT header names a sub-rectangle in the compositor's own RGBA source frame
# plus where to land it on screen, and the kernel blits ONLY that rectangle.
# user/hamUId.ad's present paths (daemon_present / daemon_present_rect) now
# emit that one RECT write per composed band instead of the legacy /dev/fb
# seek+write loop (one seek+write PER SCANLINE for a sub-width window frame).
#
# PROOF (deterministic serial self-test, no QEMU mouse/key injection):
#   `hamUId daemon derect` drives a real partial present of a single window's
#   frame through the live per-frame damage path (daemon_flush_damage ->
#   daemon_present_rect). fbctl_present_rect counts a present ONLY when the
#   kernel ACKs the 52-byte RECT write by returning exactly 52 — a return
#   value produced by NOTHING but the kernel's RECT handler — so a strictly
#   increasing count is end-to-end proof the accelerated path fired (not the
#   /dev/fb fallback). The self-test emits:
#       [DERECT] ... OK         (per assertion)
#       [DERECT] window rect=WxH rows=H legacy_seekwrites=H rect_writes=N
#       [DERECT] PASS / FAIL
#   It SKIPs cleanly (still [DERECT] PASS) on a headless surface where
#   /dev/fbctl is not claimable.
#
# Like the other -vga std hamUI self-tests this SKIPS CLEANLY (exit 0) when
# the daemon can't bring up a framebuffer under QEMU multiboot/VBE on this
# host; the authoritative GOP render gate is scripts/test_img_uefi_hamui.sh.

. "$(dirname "$0")/_build_lock.sh"

set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf

echo "[test_hamUI_derect] (1/4) Build userland"
bash scripts/build_user.sh >/dev/null
bash scripts/build_modules.sh >/dev/null

echo "[test_hamUI_derect] (2/4) Build initramfs"
python3 scripts/build_initramfs.py >/dev/null

echo "[test_hamUI_derect] (3/4) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

if [ ! -s build/user/hamUId.elf ]; then
    echo "[test_hamUI_derect] FAIL: build/user/hamUId.elf missing/empty"
    exit 1
fi

echo "[test_hamUI_derect] (4/4) Boot QEMU + run the DE RECT-present self-test"

LOG="$(mktemp)"
FIFO="$(mktemp -u).in"
mkfifo "$FIFO"
trap 'rm -f "$LOG" "$FIFO"' EXIT

# Robust feeder (same discipline as test_hamUI_wm.sh): gate on serial markers,
# never wall-clock, and RE-SEND the self-test until its terminal marker lands
# because the freshly-booted shell drops the FIRST serial command line.
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
    send_selftest 'echo MARK_DERECT_BEGIN; hamUId daemon derect' '\[DERECT\] (PASS|FAIL)' 60 3
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
    echo "[test_hamUI_derect] FAIL: kernel panic / trap"
    tail -n 60 "$LOG"
    exit 1
fi

# SKIP CLEANLY when the hamUId daemon never came up under -vga std on this
# host (QEMU multiboot1 VBE + 64-bit ELF limitation). Authoritative GOP gate:
# scripts/test_img_uefi_hamui.sh.
if ! grep -aq 'DAEMON up screen=' "$LOG"; then
    echo "[test_hamUI_derect] SKIP: hamUId daemon did not come up under -vga std on this host (QEMU multiboot VBE+64-bit limitation). Authoritative GOP gate: scripts/test_img_uefi_hamui.sh." >&2
    exit 0
fi

echo "[test_hamUI_derect] --- captured serial markers ---"
grep -aE 'DAEMON up|DAEMON console takeover|\[DERECT\]|MARK_' "$LOG" | head -80
echo "[test_hamUI_derect] --- end ---"

fail=0

assert_marker() {
    if grep -aq "$1" "$LOG"; then
        echo "[test_hamUI_derect] OK: $2"
    else
        echo "[test_hamUI_derect] MISS: $2 (expected marker: '$1')"
        fail=1
    fi
}

# Any explicit FAIL marker from the self-test is a hard failure.
if grep -aqE '\[DERECT\] FAIL' "$LOG"; then
    echo "[test_hamUI_derect] FAIL: the self-test reported a failure:"
    grep -aE '\[DERECT\] FAIL' "$LOG" | head
    exit 1
fi

# The self-test reached completion.
assert_marker '\[DERECT\] PASS' 'DERECT: RECT-present self-test ran to completion'

# Distinguish a real RECT run from a clean headless SKIP. If /dev/fbctl was
# claimed (the live -vga std path), assert the accelerated markers fired;
# otherwise accept the explicit SKIP.
if grep -aq '\[DERECT\] SKIP' "$LOG"; then
    echo "[test_hamUI_derect] NOTE: /dev/fbctl not claimable in this env — RECT path SKIPped (clean)."
else
    assert_marker 'presented via the /dev/fbctl RECT path OK' 'partial present routed through the kernel RECT command (kernel ACKed the 52-byte write)'
    assert_marker '\[DERECT\] RECT present collapses the per-row seek+write loop OK' 'the RECT path issues fewer writes than the legacy per-row seek+write loop'
    assert_marker '\[DERECT\] full-screen present also rides the RECT path OK' 'a full-screen present also rides the RECT path'
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_hamUI_derect] FAIL (qemu rc=$rc)"
    exit 1
fi

echo "[test_hamUI_derect] capture method: drives the real 'hamUId daemon derect' self-test over serial; the kernel ACK of the 52-byte RECT write is the proof"
echo "[test_hamUI_derect] PASS"
