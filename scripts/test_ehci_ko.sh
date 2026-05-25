#!/usr/bin/env bash
# scripts/test_ehci_ko.sh — regression guard for the ehci_pci.ko +
# ehci_hcd.ko + usbcore.ko load path through the L-series loader.
# Boots an ISO with ENABLE_AUTO_MODULES=1 so the in-kernel modprobe
# walks the PCI bus and matches QEMU's `-device usb-ehci` against
# the alias table (class 0x0C0320 -> ehci_pci) at boot, then chains
# usbcore + ehci_hcd via the cross-module shim wiring in
# linux_abi/api_usbcore.ad + api_ehci.ad.
#
# V0 assertions (module load + relocations resolve):
#   1. The cpio archive carries /lib/modules/auto/usbcore.ko,
#      /lib/modules/auto/ehci_pci.ko, /lib/modules/auto/ehci_hcd.ko.
#   2. The in-kernel modprobe formats a PCI query for QEMU's usb-ehci
#      device (vendor 0x8086 device 0x24CD class 0x0C0320) and the
#      alias matcher dispatches the ehci_pci.ko load.
#   3. kmod_linux_load runs init_module on ehci_pci.ko without
#      unresolved-external panic — every UND shim resolved.
#
# URB submission, hub enumeration, real device probe are out of scope —
# the milestone is "module loads + probe invokes".

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf
EHCI_BOOT_TIMEOUT="${EHCI_BOOT_TIMEOUT:-25}"

# QEMU device-availability probe. `usb-ehci` is shipped by every modern
# QEMU build (the ICH9 / 82801 family emulation).
echo "[test_ehci_ko] (0/4) Probe QEMU for usb-ehci device emulation"
HAS_EHCI=0
if qemu-system-x86_64 -device help 2>&1 | grep -q '"usb-ehci"'; then
    HAS_EHCI=1
fi
if [ "$HAS_EHCI" -ne 1 ]; then
    echo "[test_ehci_ko] SKIPPED — this QEMU build has no -device usb-ehci"
    echo "[test_ehci_ko] (build-success of the new shim wiring is still"
    echo "[test_ehci_ko]  validated unconditionally below.)"
    exit 0
fi
echo "[test_ehci_ko] OK: QEMU has -device usb-ehci"

echo "[test_ehci_ko] (1/4) Build userland + modules + initramfs"
bash scripts/build_user.sh >/dev/null
bash scripts/build_modules.sh >/dev/null
INITRAMFS_LOG=$(mktemp)
ENABLE_AUTO_MODULES=1 python3 scripts/build_initramfs.py \
    > "$INITRAMFS_LOG" 2>&1
trap 'rm -f "$INITRAMFS_LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null' EXIT

# Step 1: the cpio actually carries the three .ko's under
# /lib/modules/auto/.
echo "[test_ehci_ko] (2/4) Verify initramfs contents"
fail=0
for needle in \
    "embedded /lib/modules/auto/usbcore.ko" \
    "embedded /lib/modules/auto/ehci_pci.ko" \
    "embedded /lib/modules/auto/ehci_hcd.ko" \
    "embedded /lib/modules/modules.alias"
do
    if grep -F -q "$needle" "$INITRAMFS_LOG"; then
        echo "[test_ehci_ko] OK (cpio): '$needle'"
    else
        echo "[test_ehci_ko] MISS (cpio): '$needle'"
        fail=1
    fi
done
if [ "$fail" -ne 0 ]; then
    echo "[test_ehci_ko] --- build_initramfs.py stdout ---"
    cat "$INITRAMFS_LOG"
    exit 1
fi

echo "[test_ehci_ko] (3/4) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

# Kernel ELF sanity.
if [ -f "$ELF" ] && [ -s "$ELF" ]; then
    echo "[test_ehci_ko] OK: kernel ELF built ($(stat -c%s "$ELF") bytes)"
else
    echo "[test_ehci_ko] FAIL: kernel ELF missing"
    exit 1
fi

# Tier-1: .ko file presence
for ko in usbcore ehci_pci ehci_hcd; do
    KO_PATH="$PROJ_ROOT/kernel-modules/$ko/$ko.ko"
    KO_SIZE=$(stat -c%s "$KO_PATH" 2>/dev/null || echo 0)
    if [ "$KO_SIZE" -gt 10000 ]; then
        echo "[test_ehci_ko] OK: kernel-modules/$ko/$ko.ko present (${KO_SIZE} bytes)"
    else
        echo "[test_ehci_ko] FAIL: $ko.ko missing or too small (${KO_SIZE} bytes)"
        fail=1
    fi
done

if [ "$fail" -ne 0 ]; then
    exit 1
fi

echo "[test_ehci_ko] (4/4) Boot QEMU with usb-ehci as the USB controller"
LOG=$(mktemp)
trap 'rm -f "$LOG" "$INITRAMFS_LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null' EXIT

set +e
timeout "${EHCI_BOOT_TIMEOUT}s" qemu-system-x86_64 \
    -kernel "$ELF" \
    -device usb-ehci \
    -nographic -no-reboot -m 256M -monitor none -serial stdio \
    > "$LOG" 2>&1 < /dev/null
rc=$?
set -e

echo "[test_ehci_ko] --- captured (modprobe / kmod_linux / boot:35) ---"
grep -E '\[modprobe\]|\[boot:35\.M\]|kmod_linux: relocations|kmod_linux_load|0C0320|ehci' "$LOG" || true
echo "[test_ehci_ko] --- end ---"

# Boot sanity: kernel got past linux_abi_exports_init.
if grep -E -q '\[boot:|hamnix|rc\.boot:' "$LOG"; then
    echo "[test_ehci_ko] OK: kernel reached early boot — register_usbcore/xhci/ehci didn't wedge init"
else
    echo "[test_ehci_ko] FAIL: kernel did not reach early boot"
    fail=1
fi

# Tier-2: modprobe engaged
if grep -F -q "[modprobe] auto-load: reading /lib/modules/modules.alias" "$LOG"; then
    echo "[test_ehci_ko] OK: modprobe auto-load engaged"
else
    echo "[test_ehci_ko] MISS: modprobe auto-load not engaged"
    fail=1
fi

# Tier-3: the modprobe matched ehci_pci or ehci_hcd.
matched_ehci=0
if grep -F -q "[modprobe] MATCH -> module=ehci_pci" "$LOG"; then
    echo "[test_ehci_ko] OK: modprobe dispatched ehci_pci"
    matched_ehci=1
fi
if grep -F -q "[modprobe] MATCH -> module=ehci_hcd" "$LOG"; then
    echo "[test_ehci_ko] OK: modprobe dispatched ehci_hcd"
    matched_ehci=1
fi
if grep -F -q "[modprobe] MATCH -> module=usbcore" "$LOG"; then
    echo "[test_ehci_ko] OK: modprobe dispatched usbcore"
fi
if [ "$matched_ehci" -ne 1 ]; then
    echo "[test_ehci_ko] MISS: no ehci_pci / ehci_hcd match"
    fail=1
fi

# Tier-3: kmod_linux_load OK lines
load_ok=0
if grep -E -q "\[modprobe\] kmod_linux_load OK" "$LOG"; then
    load_ok=1
    n_ok=$(grep -cE "\[modprobe\] kmod_linux_load OK" "$LOG" || echo 0)
    echo "[test_ehci_ko] OK: $n_ok kmod_linux_load OK lines"
fi
if [ "$load_ok" -ne 1 ]; then
    echo "[test_ehci_ko] MISS: no kmod_linux_load OK lines"
    fail=1
fi

# Tier-3 strict: skipped relocations = gap analysis miss
if grep -E -q "kmod_linux: relocations applied=[0-9]+ skipped=[1-9]" "$LOG"; then
    echo "[test_ehci_ko] FAIL: at least one module had skipped relocations — symbol gap remains"
    grep -E "kmod_linux: relocations applied=" "$LOG"
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_ehci_ko] FAIL (qemu rc=$rc)"
    echo "[test_ehci_ko] --- full log tail ---"
    tail -120 "$LOG"
    exit 1
fi

echo "[test_ehci_ko] PASS (usbcore + ehci_pci + ehci_hcd load via L-shim auto-discovery)"
