#!/usr/bin/env bash
# scripts/test_xhci_io.sh — USB host-controller class L-shim EXERCISE test.
#
# The companion `test_xhci_ko.sh` is a LOAD-only test: it asserts the
# Debian 6.1.0-32 xhci_pci.ko binary's UND surface is closed by
# linux_abi/api_xhci.ad + api_usbcore.ad and that init_module / probe
# runs through the cold-path stubs. That's necessary but not sufficient
# — it doesn't prove anything about real USB controller ownership.
#
# This script is the EXERCISE: boot with a real USB host controller +
# USB keyboard attached via `-device qemu-xhci,id=xhci -device
# usb-kbd,bus=xhci.0`, set /etc/xhci-ko to (a) skip the hand-rolled
# drivers/usb/xhci.ad + ehci.ad init paths and (b)
# modules_dep_load_with_deps("xhci_pci"), then run xhci_io_exercise()
# in init/main.ad which asserts the dep walker landed the
# usbcore + xhci-hcd + xhci_pci chain and that xhci_pci's probe ran
# through usb_add_hcd.
#
# The PASS / FAIL channel is the [xhci_io_test] marker line emitted
# from xhci_io_exercise(). Whichever happens — PASS or a specific FAIL
# reason — the test script reports it. The shape mirrors
# test_ahci_io.sh (storage class) and test_e1000e_traffic.sh (NIC
# class): the marker file is the unit of measure for whether the
# L-shim subsystem of THAT device class can carry real ownership.
#
# Architecture note (M16.x): the .ko's stock USB-HID interrupt-IN
# URB submission path requires a working xhci ring-doorbell + command
# event ring (DMA-coherent allocs the chip dereferences). That's the
# follow-up milestone — this exercise validates everything UP TO and
# INCLUDING root-hub registration. It does NOT inject a keystroke via
# QEMU monitor `sendkey` because the URB path isn't wired yet. Once
# usb_submit_urb does real work, this script extends to add a sendkey
# stage and assert a matching [input] event in the Hamnix input layer.
#
# Bridge philosophy: unlike test_ahci_io.sh which has a [bridge=
# fallback] arm that falls back to drivers/ata/ahci.ad if the L-shim
# can't complete add_disk, this test has NO BRIDGE. The hand-rolled
# drivers/usb/xhci.ad is gated OFF at boot:01 by the marker. If the
# L-shim can't enumerate, the [bridge=disabled] marker is the
# headline — same shape as test_nvme_io.sh.

. "$(dirname "$0")/_build_lock.sh"

set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf
XHCI_IO_TIMEOUT="${XHCI_IO_TIMEOUT:-30}"

# QEMU device-availability probe. Modern QEMU builds (>= 2.5) ship
# `-device qemu-xhci` unconditionally; older builds need
# `-device nec-usb-xhci`. usb-kbd ships everywhere.
echo "[test_xhci_io] (0/5) Probe QEMU for xhci + usb-kbd"
HAS_XHCI=0
XHCI_DEVICE=""
if qemu-system-x86_64 -device help 2>&1 | grep -q '"qemu-xhci"'; then
    HAS_XHCI=1
    XHCI_DEVICE="qemu-xhci"
elif qemu-system-x86_64 -device help 2>&1 | grep -q '"nec-usb-xhci"'; then
    HAS_XHCI=1
    XHCI_DEVICE="nec-usb-xhci"
fi
if [ "$HAS_XHCI" -ne 1 ]; then
    echo "[test_xhci_io] SKIPPED — this QEMU build has no xhci device emulation"
    exit 0
fi
if ! qemu-system-x86_64 -device help 2>&1 | grep -q '"usb-kbd"'; then
    echo "[test_xhci_io] SKIPPED — this QEMU build has no usb-kbd"
    exit 0
fi
echo "[test_xhci_io] OK: QEMU has -device $XHCI_DEVICE + usb-kbd"

echo "[test_xhci_io] (1/5) Build userland + modules"
bash scripts/build_user.sh >/dev/null
bash scripts/build_modules.sh >/dev/null

echo "[test_xhci_io] (2/5) Build initramfs with /etc/xhci-ko marker"
INITRAMFS_LOG=$(mktemp)
ENABLE_XHCI_KO=1 INIT_ELF=build/user/init.elf \
    python3 scripts/build_initramfs.py > "$INITRAMFS_LOG" 2>&1

# Verify the .ko's plant at /lib/modules/ + the cpio carries
# modules.dep + the /etc/xhci-ko marker.
fail=0
for needle in \
    "embedded /lib/modules/usbcore.ko" \
    "embedded /lib/modules/xhci_pci.ko" \
    "embedded /lib/modules/xhci-hcd.ko" \
    "embedded /lib/modules/modules.dep"
do
    if grep -F -q "$needle" "$INITRAMFS_LOG"; then
        echo "[test_xhci_io] OK (cpio): '$needle'"
    else
        echo "[test_xhci_io] MISS (cpio): '$needle'"
        fail=1
    fi
done
if [ "$fail" -ne 0 ]; then
    echo "[test_xhci_io] --- build_initramfs.py stdout ---"
    cat "$INITRAMFS_LOG"
    rm -f "$INITRAMFS_LOG"
    INIT_ELF=build/user/init.elf \
        python3 scripts/build_initramfs.py >/dev/null 2>&1 || true
    exit 1
fi
rm -f "$INITRAMFS_LOG"

echo "[test_xhci_io] (3/5) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

LOG="$(mktemp)"
# Restore the default initramfs at the end so subsequent tests don't
# inherit ENABLE_XHCI_KO state.
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1 || true' EXIT

echo "[test_xhci_io] (4/5) Boot QEMU with $XHCI_DEVICE + usb-kbd"
set +e
timeout "${XHCI_IO_TIMEOUT}s" qemu-system-x86_64 \
    -kernel "$ELF" \
    -device "$XHCI_DEVICE,id=xhci0" \
    -device "usb-kbd,bus=xhci0.0" \
    -smp 2 -nographic -no-reboot -m 256M \
    -monitor none -serial stdio \
    > "$LOG" 2>&1 < /dev/null
rc=$?
set -e

echo "[test_xhci_io] (5/5) Inspect log"
echo "[test_xhci_io] --- captured (xhci / xhci_io_test / ksymtab / boot:35.X / kmod) ---"
grep -aE 'kmod_linux: name=|modules_dep|\[xhci_io_test\]|\[ksymtab_hit\] (xhci_pci|xhci_hcd)|\[boot:35\.X\]|\[boot:01\]|\[boot:02\]|\[xhci\] hand-rolled|\[ehci\] hand-rolled|\[pci_register_driver\] (MATCH 1b36|USB host-controller|V0 milestone|matched|skipping probe|enumerated)|\[usb\] enumerated' "$LOG" | head -80 || true
echo "[test_xhci_io] --- end ---"

# Panic / TRAP / BUG is unambiguously a regression.
if grep -aE -q "PANIC|panic:|TRAP:|BUG:" "$LOG"; then
    echo "[test_xhci_io] FAIL: kernel panic / trap"
    echo "[test_xhci_io] --- full log tail ---"
    tail -n 80 "$LOG"
    exit 1
fi

# Marker plumbing sanity: the boot:35.X header must fire.
if ! grep -aF -q '[boot:35.X] modules_dep_load_with_deps("xhci_pci")' "$LOG"; then
    echo "[test_xhci_io] FAIL: /etc/xhci-ko marker not honoured"
    echo "[test_xhci_io] --- full log tail ---"
    tail -n 80 "$LOG"
    exit 1
fi
echo "[test_xhci_io] OK: /etc/xhci-ko marker honoured"

# Hand-rolled gate fired (both xhci_init and ehci_init skipped).
if ! grep -aF -q "[xhci] hand-rolled init SKIPPED" "$LOG"; then
    echo "[test_xhci_io] FAIL: hand-rolled xhci_init not gated off"
    exit 1
fi
if ! grep -aF -q "[ehci] hand-rolled init SKIPPED" "$LOG"; then
    echo "[test_xhci_io] FAIL: hand-rolled ehci_init not gated off"
    exit 1
fi
echo "[test_xhci_io] OK: hand-rolled drivers/usb/{xhci,ehci}.ad gated off"

# The modules.dep dep chain must have auto-loaded usbcore + xhci-hcd
# BEFORE xhci_pci. Assert each name landed in the kmod_linux: log
# stream so a regression that drops back to single-module insmod is
# loud. The dep walker normalizes 'xhci-hcd' -> the cpio path
# /lib/modules/xhci-hcd.ko; kmod_linux: prints the modinfo -F name
# from the .ko which is 'xhci_hcd' (underscore form).
for dep_name in usbcore xhci_hcd xhci_pci; do
    if ! grep -aE -q "kmod_linux: name=${dep_name}" "$LOG"; then
        echo "[test_xhci_io] FAIL: modules.dep dep chain did not load ${dep_name}"
        echo "[test_xhci_io] --- full log tail ---"
        tail -n 80 "$LOG"
        exit 1
    fi
done
echo "[test_xhci_io] OK: modules.dep chain loaded usbcore+xhci_hcd+xhci_pci"

# Cross-module ksymtab dispatch: xhci_pci.ko's usb_add_hcd /
# usb_create_shared_hcd / xhci_gen_setup must resolve via
# usbcore.ko's / xhci_hcd.ko's __ksymtab entries (not the
# api_usbcore.ad / api_xhci.ad cold-path stubs). usb_add_hcd is the
# canonical "the USB stack accepted this controller" marker.
if ! grep -aE -q "\[ksymtab_hit\] xhci_pci -> usbcore: usb_add_hcd" "$LOG"; then
    echo "[test_xhci_io] FAIL: cross-module ksymtab did not resolve usb_add_hcd"
    echo "[test_xhci_io] --- full log tail ---"
    tail -n 80 "$LOG"
    exit 1
fi
echo "[test_xhci_io] OK: ksymtab dispatched xhci_pci -> usbcore: usb_add_hcd"

# QEMU's qemu-xhci PCI signature is 1b36:000d (Red Hat virtio-xhci).
# The kernel's pci_register_driver walk must encounter and try to
# probe it (proves the device is on the bus AND the .ko registered a
# pci_driver whose id_table matches). The kernel printk emits the
# hex tuple in lowercase ("MATCH 1b36:d" — _printk_hex strips leading
# zeros) so the grep below is lowercase + tolerates the d/000d split.
if ! grep -aiE -q "\[pci_register_driver\] MATCH 1b36:0*d\b" "$LOG"; then
    echo "[test_xhci_io] WARN: pci_register_driver did not MATCH 1b36:000d"
    echo "[test_xhci_io]   (qemu-xhci PCI device may not be visible to the"
    echo "[test_xhci_io]    in-kernel PCI bus walker — orthogonal regression)"
else
    echo "[test_xhci_io] OK: pci_register_driver matched qemu-xhci (1b36:000d)"
fi

# The L-shim USB enumeration marker — the [usb] line our
# pci_register_driver shim emits when the matched device is a USB
# host-controller class (0x0C03xx). Acts as the user-facing "USB
# controller seen" signal regardless of how the deeper probe path
# fares.
if grep -aE -q "\[usb\] enumerated controller vid=1b36 pid=d\b" "$LOG"; then
    echo "[test_xhci_io] OK: [usb] enumerated controller emitted for qemu-xhci"
else
    echo "[test_xhci_io] WARN: [usb] enumerated controller line missing"
fi

# Bridge=disabled marker — the headline "no native fallback in play".
if ! grep -aF -q "[bridge=disabled]" "$LOG"; then
    echo "[test_xhci_io] FAIL: [bridge=disabled] marker missing"
    exit 1
fi
echo "[test_xhci_io] OK: [bridge=disabled] — L-shim owns USB controller end to end"

# PASS / FAIL channel.
PASS_HIT=$(grep -acE "\[xhci_io_test\] PASS" "$LOG" || true)
PASS_HIT=${PASS_HIT:-0}
FAIL_HIT=$(grep -acE "\[xhci_io_test\] FAIL" "$LOG" || true)
FAIL_HIT=${FAIL_HIT:-0}

if [ "$PASS_HIT" -ge 1 ]; then
    echo "[test_xhci_io] PASS: L-shim usbcore + xhci_pci + xhci_hcd dep chain landed; root hub registered"
    echo "[test_xhci_io]   (URB-submission / sendkey injection is the next milestone — see"
    echo "[test_xhci_io]    init/main.ad's xhci_io_exercise comment for the gap analysis)"
    exit 0
fi

if [ "$FAIL_HIT" -ge 1 ]; then
    echo "[test_xhci_io] FAIL (informative — surfaces a USB L-shim gap):"
    grep -aE "\[xhci_io_test\]" "$LOG" || true
    exit 1
fi

echo "[test_xhci_io] FAIL: no [xhci_io_test] marker seen (qemu rc=$rc)"
echo "[test_xhci_io] --- full log tail ---"
tail -n 80 "$LOG"
exit 1
