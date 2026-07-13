#!/usr/bin/env bash
# scripts/test_atkbd_ext.sh — M16.100 regression for the polished
# PS/2 keyboard driver: extended scancode decoding, modifier-state
# tracking, Shift/Caps/Ctrl transforms, VT220/xterm escape emission.
#
# Test strategy: drivers/input/atkbd.ad runs a boot-time self-test
# (atkbd_self_test) that feeds 12 synthetic scancode sequences
# through atkbd_process_byte() and asserts the bytes that land in
# the software FIFO. The self-test prints
#   "atkbd: self-test PASS (N cases)"
# on success and
#   "atkbd: self-test FAIL (...)"
# on failure. We assert on the PASS banner over QEMU's serial.
#
# Why this shape and NOT a QEMU `-monitor sendkey` fixture:
# `sendkey` requires the QMP socket or `-monitor stdio` (mutually
# exclusive with `-serial stdio` which we're already using for the
# log), making the test pipeline awkward + flaky. The synthetic-
# scancode self-test exercises the same code paths
# (atkbd_process_byte + the modifier state machine + the extended-
# prefix decoder) deterministically. Manual end-to-end smoke test
# with a real PS/2 keyboard or `-monitor stdio sendkey shift-a`
# remains a follow-up.
#
# Cases covered by the self-test (each documented in the driver):
#   1. lowercase 'a'
#   2. Shift+'a' -> 'A'
#   3. CapsLock latches; break does not toggle; second 'a' still 'A'
#   4. Shift XOR Caps -> 'a' (both pressed cancels)
#   5. Shift+'1' -> '!'
#   6. Ctrl+'c' -> 0x03 (SIGINT byte)
#   7. Ctrl+Shift+'d' -> 0x04
#   8. Arrow Up -> ESC [ A
#   9. Delete -> ESC [ 3 ~
#  10. F1 -> ESC O P
#  11. F5 -> ESC [ 1 5 ~
#  12. extended-form right Ctrl + 'c' -> 0x03, release clears state
#
# PASS criterion: "atkbd: self-test PASS (46 cases)" appears in the
# serial log (46 == total expect_byte calls across the scenarios,
# incl. the Ctrl+Alt+Left/Right and Ctrl+Alt+T MATE chords).

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf

echo "[test_atkbd_ext] (1/3) Build userland (so /init = init.elf exists)"
bash scripts/build_user.sh >/dev/null
bash scripts/build_modules.sh >/dev/null

echo "[test_atkbd_ext] (2/3) Build default initramfs"
INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null

echo "[test_atkbd_ext] (3/3) Rebuild kernel + boot QEMU for self-test"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

LOG=$(mktemp)
trap 'rm -f "$LOG"' EXIT

set +e
timeout 10s qemu-system-x86_64 \
    -kernel "$ELF" \
    -smp 2 \
    -nographic \
    -no-reboot \
    -m 256M \
    -monitor none \
    -serial stdio \
    > "$LOG" 2>&1
rc=$?
set -e

echo "[test_atkbd_ext] --- captured boot output ---"
grep -E "atkbd:" "$LOG" || true
echo "[test_atkbd_ext] --- end ---"

fail=0
# The exact expected banner. The "46 cases" is derived from the
# number of _selftest_expect_byte calls inside atkbd_self_test —
# bump together with the driver if you add cases.
if grep -F -q "atkbd: self-test PASS (46 cases)" "$LOG"; then
    echo "[test_atkbd_ext] OK: self-test PASS banner present"
else
    echo "[test_atkbd_ext] MISS: self-test PASS banner absent"
    fail=1
fi

# The "ready" banner proves init() reached the end of atkbd_init()
# (i.e. the self-test didn't panic / hang the kernel between
# atkbd_self_test() and the final printk0).
if grep -F -q "atkbd: ready" "$LOG"; then
    echo "[test_atkbd_ext] OK: atkbd_init reached ready banner"
else
    echo "[test_atkbd_ext] MISS: atkbd_init did not complete"
    fail=1
fi

# Defensive: a FAIL line should NEVER appear. If it does, the cases
# count above probably still matched some other PASS line — explicit
# check to be safe.
if grep -F -q "atkbd: self-test FAIL" "$LOG"; then
    echo "[test_atkbd_ext] MISS: self-test FAIL line present"
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_atkbd_ext] FAIL (qemu rc=$rc)"
    exit 1
fi

echo "[test_atkbd_ext] PASS"
