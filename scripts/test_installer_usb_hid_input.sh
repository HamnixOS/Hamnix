#!/usr/bin/env bash
# scripts/test_installer_usb_hid_input.sh — regression for USB HID INPUT
# bring-up on the INSTALLER MEDIUM (the USB-only NUC's mouse/keyboard).
#
# THE BUG THIS GUARDS AGAINST. The in-RAM installer medium boots with
# /etc/installer-medium planted. Before this fix, init/main.ad's boot:01
# branch SKIPPED xhci_init() entirely under that marker ("USB off boot
# path") — correct for STORAGE (the installer payload rides in RAM, the
# media has nothing to read), but it ALSO killed USB HID INPUT. The real
# NUC (i7-6770HQ) has NO PS/2 mouse/keyboard: input must come from a USB
# HID device over the native xHCI controller. So the GUI (runlevel 5)
# came up with a DEAD mouse on the NUC, while every VM (PS/2 / virtio)
# worked fine. The fix: the installer-medium branch now calls
# xhci_init_force() — bringing up the controller + HID interrupt-IN
# polling (keyboard AND mouse) WITHOUT any media read — while still
# honoring the /etc/xhci-no-init opt-out and keeping every MMIO poll
# software-bounded.
#
# WHAT THIS ASSERTS. Boot QEMU with /etc/installer-medium planted (via
# ENABLE_INSTALLER_MEDIUM_MARKER=1 — the marker ONLY, no squashfs, so the
# test is fast) and a `qemu-xhci` bus carrying a `usb-mouse` + `usb-kbd`.
# Then assert:
#
#   1. The installer-medium branch took the NEW force route, not the old
#      full-skip:  "[boot:01] xhci_init_force (installer medium: USB HID
#                   input ...)"
#   2. The controller actually came up (BAR0 + caps decoded, reset done).
#   3. The boot-MOUSE interface enumerated live: the
#      "bInterfaceProtocol=0x02 MOUSE" match marker fired and the mouse
#      attach reached "complete (interrupt-IN polling LIVE ...)".
#   4. The synthetic hid_mouse_report -> mouse_rx_push -> /dev/mouse
#      decode self-test still PASSES (the downstream encoding the DE
#      consumes):  "[usb_hid_mouse] self-test PASS (7 cases)".
#   5. No regression: the USB keyboard HID path + the PS/2 atkbd path
#      both still self-test PASS.
#
# Pass marker:    [installer_usb_hid_input] PASS
# Fail marker:    [installer_usb_hid_input] FAIL

set -euo pipefail

PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

# shellcheck source=_build_lock.sh
source "$PROJ_ROOT/scripts/_build_lock.sh"

ELF=build/hamnix-kernel.elf

echo "[installer_usb_hid_input] (1/3) Build userland + modules (init.elf for cpio)"
bash scripts/build_user.sh >/dev/null
bash scripts/build_modules.sh >/dev/null

echo "[installer_usb_hid_input] (2/3) Build initramfs with /etc/installer-medium marker (no squashfs)"
# ENABLE_INSTALLER_MEDIUM_MARKER plants ONLY /etc/installer-medium so the
# installer-medium HID-input code path runs without building the full
# multi-hundred-MiB installer image. The trap restores a clean default
# initramfs so later test runs aren't polluted.
INIT_ELF=build/user/init.elf ENABLE_INSTALLER_MEDIUM_MARKER=1 \
    python3 scripts/build_initramfs.py >/dev/null

echo "[installer_usb_hid_input] (3/3) Rebuild kernel + boot QEMU (qemu-xhci + usb-mouse + usb-kbd)"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null' EXIT

set +e
timeout 30s qemu-system-x86_64 \
    -kernel "$ELF" \
    -smp 2 \
    -nographic \
    -no-reboot \
    -m 256M \
    -monitor none \
    -serial stdio \
    -device qemu-xhci \
    -device usb-kbd \
    -device usb-mouse \
    > "$LOG" 2>&1
rc=$?
set -e

echo "[installer_usb_hid_input] --- captured installer-medium HID-input boot output ---"
grep -E "installer medium|xhci|usb_hid|usb_hid_mouse|atkbd:|01\.h" "$LOG" || true
echo "[installer_usb_hid_input] --- end ---"

fail=0

# --- 1. NEW force route taken under the installer-medium marker --------
# This is THE load-bearing assertion: the old code printed
# "[boot:01] xhci_init SKIPPED (installer medium ...)"; the fix prints
# "[boot:01] xhci_init_force (installer medium: USB HID input ...)".
if grep -F -q "xhci_init_force (installer medium: USB HID input" "$LOG"; then
    echo "[installer_usb_hid_input] OK: installer-medium branch took the xhci_init_force HID route"
else
    echo "[installer_usb_hid_input] MISS: installer-medium branch did NOT force xHCI HID bring-up"
    fail=1
fi
# And the old full-skip line must be GONE (would mean the regression came back).
if grep -F -q "xhci_init SKIPPED (installer medium" "$LOG"; then
    echo "[installer_usb_hid_input] MISS: OLD full-skip path still active (mouse would be dead on the NUC)"
    fail=1
fi

# --- 2. Controller came up (BAR + caps + reset) -----------------------
if grep -F -q "[xhci] controller found" "$LOG" \
   && grep -E -q "\[xhci\] max_slots=[0-9]+ max_ports=[0-9]+" "$LOG" \
   && grep -F -q "[xhci] controller reset complete" "$LOG"; then
    echo "[installer_usb_hid_input] OK: xHCI controller PCI-found + caps decoded + reset"
else
    echo "[installer_usb_hid_input] MISS: xHCI controller did not come up under force route"
    fail=1
fi

# --- 3. Live boot-MOUSE enumeration (protocol 0x02 + polling LIVE) -----
if grep -F -q "mouse interface matched (bInterfaceProtocol=0x02 MOUSE)" "$LOG"; then
    echo "[installer_usb_hid_input] OK: boot-mouse interface matched (bInterfaceProtocol=0x02)"
else
    echo "[installer_usb_hid_input] MISS: boot-mouse interface (protocol 0x02) never matched"
    fail=1
fi
if grep -F -q "xhci mouse attach: complete (interrupt-IN polling LIVE" "$LOG"; then
    echo "[installer_usb_hid_input] OK: mouse interrupt-IN endpoint armed + polling LIVE"
else
    echo "[installer_usb_hid_input] MISS: mouse attach never reached the polling-LIVE marker"
    fail=1
fi

# --- 4. Synthetic mouse decode path (hid_mouse_report -> /dev/mouse) ---
if grep -E -q "\[usb_hid_mouse\] self-test PASS \([0-9]+ cases\)" "$LOG"; then
    echo "[installer_usb_hid_input] OK: hid_mouse_report -> mouse_rx_push self-test PASS"
else
    echo "[installer_usb_hid_input] MISS: HID mouse decode self-test PASS banner absent"
    fail=1
fi
if grep -F -q "[usb_hid_mouse] self-test FAIL" "$LOG"; then
    echo "[installer_usb_hid_input] MISS: HID mouse decode self-test reported FAIL"
    fail=1
fi

# --- 5. No regression: USB kbd + PS/2 atkbd still self-test PASS -------
if grep -F -q "[usb_hid] self-test PASS (17 cases)" "$LOG"; then
    echo "[installer_usb_hid_input] OK: USB keyboard HID self-test still PASS (kbd path also up)"
else
    echo "[installer_usb_hid_input] MISS: USB keyboard HID self-test regressed"
    fail=1
fi
if grep -F -q "atkbd: self-test PASS (25 cases)" "$LOG"; then
    echo "[installer_usb_hid_input] OK: PS/2 atkbd self-test still PASS (no regression)"
else
    echo "[installer_usb_hid_input] MISS: PS/2 atkbd self-test regressed"
    fail=1
fi

echo "[installer_usb_hid_input] (qemu exit rc=$rc)"
if [ "$fail" -eq 0 ]; then
    echo "[installer_usb_hid_input] PASS"
    exit 0
else
    echo "[installer_usb_hid_input] FAIL"
    exit 1
fi
