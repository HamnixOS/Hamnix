#!/usr/bin/env bash
# scripts/test_mouse.sh — PS/2 auxiliary-device (mouse) regression.
#
# What this asserts (init + decoder; not live packet delivery):
#   - i8042 second-port enable + CCB write completed
#     ("auxmouse: i8042 second port enabled")
#   - Mouse reset + BAT pass + device-ID readout
#     ("auxmouse: ID=0x0 (standard 3-byte PS/2 mouse)")
#   - Streaming enable ACK
#     ("auxmouse: streaming enabled")
#   - IOAPIC redirect + IRQ handler register
#     ("auxmouse: irq pin=12 vec=0x45")
#   - Decoder self-test PASS (synthetic 3-byte packets)
#     ("auxmouse: self-test PASS (7 cases)")
#
# Why we don't drive live packets in QEMU:
#   QEMU's `-nographic -no-reboot -monitor none` config (which the rest
#   of the test suite uses) gives us serial stdio but no QMP socket and
#   no monitor — so `mouse_move 10 20` is unreachable. The synthetic-
#   packet self-test fed through `auxmouse_process_byte()` covers the
#   decoder regressions deterministically. A future commit can add a
#   `-monitor unix:...` overlay or a QMP-driven fixture to exercise
#   real packet delivery on the IRQ 12 path.
#
# Regression coverage: this script must NOT destabilise the atkbd
# self-test — both PASS banners are asserted.

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf

echo "[test_mouse] (1/3) Build userland (so /init = init.elf exists)"
bash scripts/build_user.sh >/dev/null
bash scripts/build_modules.sh >/dev/null

echo "[test_mouse] (2/3) Build default initramfs"
INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null

echo "[test_mouse] (3/3) Rebuild kernel + boot QEMU"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

LOG=$(mktemp)
trap 'rm -f "$LOG"' EXIT

set +e
timeout 12s qemu-system-x86_64 \
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

echo "[test_mouse] --- captured auxmouse/atkbd lines ---"
grep -E "auxmouse:|atkbd:" "$LOG" || true
echo "[test_mouse] --- end ---"

fail=0

# --- Init markers (required) ---
if grep -F -q "auxmouse: i8042 second port enabled" "$LOG"; then
    echo "[test_mouse] OK: AUX port enabled"
else
    echo "[test_mouse] MISS: AUX port enable banner absent"
    fail=1
fi

if grep -F -q "auxmouse: ID=0x0 (standard 3-byte PS/2 mouse)" "$LOG"; then
    echo "[test_mouse] OK: mouse reset + ID readout"
else
    echo "[test_mouse] MISS: mouse ID banner absent"
    fail=1
fi

if grep -F -q "auxmouse: streaming enabled" "$LOG"; then
    echo "[test_mouse] OK: streaming enable ACK"
else
    echo "[test_mouse] MISS: streaming enable banner absent"
    fail=1
fi

# --- IRQ wiring marker ---
if grep -F -q "auxmouse: irq pin=12 vec=0x45" "$LOG"; then
    echo "[test_mouse] OK: IRQ 12 routed to vector 0x45"
else
    echo "[test_mouse] MISS: IRQ wiring banner absent"
    fail=1
fi

# --- Decoder self-test ---
if grep -F -q "auxmouse: self-test PASS (7 cases)" "$LOG"; then
    echo "[test_mouse] OK: decoder self-test (7 cases)"
else
    echo "[test_mouse] MISS: decoder self-test PASS banner absent"
    fail=1
fi

# A FAIL line should NEVER appear.
if grep -F -q "auxmouse: self-test FAIL" "$LOG"; then
    echo "[test_mouse] MISS: decoder self-test FAIL line present"
    fail=1
fi

# --- Keyboard regression — atkbd must still pass ---
if grep -F -q "atkbd: self-test PASS (25 cases)" "$LOG"; then
    echo "[test_mouse] OK: atkbd self-test still passes"
else
    echo "[test_mouse] MISS: atkbd self-test regressed"
    fail=1
fi

if grep -F -q "atkbd: ready" "$LOG"; then
    echo "[test_mouse] OK: atkbd_init reached ready banner"
else
    echo "[test_mouse] MISS: atkbd_init did not complete"
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_mouse] FAIL (qemu rc=$rc)"
    exit 1
fi

echo "[test_mouse] PASS"
