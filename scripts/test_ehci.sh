#!/usr/bin/env bash
# scripts/test_ehci.sh — V0+V1 regression for the EHCI (USB 2.0) host
# controller driver (drivers/usb/ehci.ad).
#
# Why this driver exists:
#   The leading hypothesis for a dead built-in keyboard on the target
#   Asus laptop is that the keyboard is wired to the EHCI controller,
#   not the i8042. Hamnix had an xHCI driver but no EHCI driver — this
#   test covers the missing host-controller backend.
#
# Test strategy:
#   Boot QEMU with `-device usb-ehci` (and `-device usb-kbd` on the
#   EHCI bus) and assert that the kernel:
#     a. PCI-scans + finds the EHCI controller (class 0x0C / 0x03 /
#        progIF 0x20),
#     b. maps BAR0 + decodes the capability registers (CAPLENGTH,
#        N_PORTS), printed in the load-bearing banner
#          "[ehci] controller at BAR0=0x... N_PORTS=N",
#     c. performs the BIOS->OS handoff (or logs that no USBLEGSUP
#        capability is present),
#     d. resets the controller, sets up the periodic frame list +
#        async QH, runs the controller, sets CONFIGFLAG,
#     e. walks the root-hub PORTSC array — with usb-kbd attached, one
#        port must come up "[ehci] port N: reset done, enabled=1".
#
#   V1 then runs the transfer engine: the async-schedule control
#   transfers drive the standard enumeration (GET_DESCRIPTOR /
#   SET_ADDRESS / GET_DESCRIPTOR(config) / SET_CONFIGURATION), and the
#   HID boot keyboard is configured with a periodic interrupt-IN QH.
#   This script asserts the enumeration reached SET_CONFIGURATION and
#   the keyboard was configured; the live-keystroke round-trip lives
#   in scripts/test_ehci_kbd.sh.
#
# Regression invariant: a panic / unexpected trap between PCI scan
# and init completion would also be caught here.
#
# Pass marker:    [test_ehci] PASS
# Fail marker:    [test_ehci] FAIL

set -uo pipefail

PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

# shellcheck source=_build_lock.sh
source "$PROJ_ROOT/scripts/_build_lock.sh"

ELF=build/hamnix-kernel.elf

# --- QEMU EHCI availability check ------------------------------------
# Some QEMU builds omit the usb-ehci device model. If it is missing,
# document and skip rather than fail — the driver itself is unchanged.
if ! qemu-system-x86_64 -device help 2>/dev/null | grep -q -i "usb-ehci"; then
    echo "[test_ehci] SKIP: this QEMU build has no usb-ehci device"
    echo "[test_ehci]   ('qemu-system-x86_64 -device help | grep -i ehci' empty)"
    exit 0
fi

echo "[test_ehci] (1/3) Build userland (init.elf must exist for cpio)"
bash scripts/build_user.sh >/dev/null
bash scripts/build_modules.sh >/dev/null

echo "[test_ehci] (2/3) Build default initramfs"
INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null

echo "[test_ehci] (3/3) Rebuild kernel + boot QEMU with usb-ehci + usb-kbd"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

LOG=$(mktemp)
trap 'rm -f "$LOG"' EXIT

# `-device usb-ehci` instantiates a standalone EHCI host controller on
# the PCI bus; `-device usb-kbd,bus=usb-bus.0` plugs a HID-class boot
# keyboard into it. usb-ehci names its bus "usb-bus.0".
set +e
timeout 25s qemu-system-x86_64 \
    -kernel "$ELF" \
    -smp 2 \
    -nographic \
    -no-reboot \
    -m 256M \
    -monitor none \
    -serial stdio \
    -device usb-ehci \
    -device usb-kbd,bus=usb-bus.0 \
    > "$LOG" 2>&1
rc=$?
set -e

echo "[test_ehci] --- captured EHCI-relevant boot output ---"
grep -E "ehci|EHCI" "$LOG" || true
echo "[test_ehci] --- end ---"

fail=0

# --- Controller-detect assertion -------------------------------------
if grep -F -q "[ehci] controller found" "$LOG"; then
    echo "[test_ehci] OK: EHCI controller detected via PCI"
else
    echo "[test_ehci] MISS: EHCI controller-found banner absent"
    fail=1
fi

# --- BAR0 + capability decode ----------------------------------------
# The load-bearing V0 banner. BAR0 must decode to a non-zero MMIO
# address and N_PORTS must be a positive integer.
if grep -E -q "\[ehci\] controller at BAR0=0x[0-9a-fA-F]+ N_PORTS=[0-9]+" "$LOG"; then
    echo "[test_ehci] OK: BAR0 mapped + capability registers decoded"
else
    echo "[test_ehci] MISS: '[ehci] controller at BAR0= N_PORTS=' banner absent"
    fail=1
fi

# --- Controller reset --------------------------------------------------
if grep -F -q "[ehci] controller reset complete" "$LOG"; then
    echo "[test_ehci] OK: HCRESET cycle complete"
else
    echo "[test_ehci] MISS: EHCI reset banner absent"
    fail=1
fi

# --- Controller running ------------------------------------------------
if grep -F -q "[ehci] controller running" "$LOG"; then
    echo "[test_ehci] OK: controller transitioned to running state"
else
    echo "[test_ehci] MISS: '[ehci] controller running' banner absent"
    fail=1
fi

# --- Port enumeration --------------------------------------------------
# THE load-bearing V0 marker with usb-kbd attached: the keyboard is a
# USB 2.0 high-speed device, so after reset its port must report
# enabled=1. If the BAR mapping or the PORTSC offset/stride decode is
# wrong, this line never appears.
if grep -E -q "\[ehci\] port [0-9]+: reset done, enabled=1" "$LOG"; then
    echo "[test_ehci] OK: root-hub high-speed device enumerated on EHCI"
else
    echo "[test_ehci] MISS: no high-speed port came up after reset"
    fail=1
fi

# --- V0 completion -----------------------------------------------------
if grep -F -q "[ehci] V0 init complete" "$LOG"; then
    echo "[test_ehci] OK: ehci_init() ran to completion"
else
    echo "[test_ehci] MISS: '[ehci] V0 init complete' banner absent"
    fail=1
fi

# --- V1: control-transfer enumeration ---------------------------------
# The transfer engine must drive the standard enumeration through
# SET_CONFIGURATION. This line proves SETUP/DATA/STATUS qTD chains on
# the async schedule actually moved bytes and the device transitioned
# to the Configured state.
if grep -F -q "[ehci] V1: device configured" "$LOG"; then
    echo "[test_ehci] OK: V1 enumeration reached SET_CONFIGURATION"
else
    echo "[test_ehci] MISS: '[ehci] V1: device configured' banner absent"
    fail=1
fi

# --- V1: HID boot keyboard configured ---------------------------------
# usb-kbd enumerates as a HID boot keyboard (class 3 / proto 1); V1
# must find its interrupt-IN endpoint and arm the periodic QH.
if grep -F -q "[ehci] HID boot keyboard configured" "$LOG"; then
    echo "[test_ehci] OK: HID boot keyboard configured on EHCI"
else
    echo "[test_ehci] MISS: '[ehci] HID boot keyboard configured' absent"
    fail=1
fi

# --- V1: synthetic transfer-engine self-test --------------------------
# Deterministic proof the interrupt-IN qTD -> hid_kbd_report -> kbd
# FIFO path moves a byte, independent of the live wire exchange.
if grep -F -q "[ehci_v1] transfer-engine PASS" "$LOG"; then
    echo "[test_ehci] OK: V1 synthetic transfer-engine self-test PASS"
else
    echo "[test_ehci] MISS: '[ehci_v1] transfer-engine PASS' absent"
    fail=1
fi

# --- Negative check: no panic / trap ----------------------------------
if grep -E -q "PANIC|panic:|TRAP: vector" "$LOG"; then
    echo "[test_ehci] MISS: kernel panic / unexpected trap in boot log"
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_ehci] FAIL (qemu rc=$rc)"
    exit 1
fi

# rc=124 is timeout — the expected "kernel HLT'd after init" outcome,
# since the kernel never powers off after start_kernel.
if [ "$rc" -ne 124 ] && [ "$rc" -ne 0 ]; then
    echo "[test_ehci] FAIL: qemu exited rc=$rc"
    exit 1
fi

echo "[test_ehci] PASS"
