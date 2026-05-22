#!/usr/bin/env bash
# scripts/test_l64_ehci_hcd.sh — L64 ehci-hcd.ko load test.
#
# Goal:
#   Ship ehci-hcd.ko (Linux's USB 2.0 host controller driver — the
#   kernel module implementing the Enhanced Host Controller Interface,
#   the USB 2.x companion to L63's xhci-hcd). ehci-hcd sits just above
#   usbcore on the USB stack; with ehci-pci or ehci-platform binding
#   it to real hardware below, ehci-hcd manages every USB High-Speed
#   (2.x) port on pre-USB-3 chipsets. 94 UND total; 86 covered by
#   L<=63 (usbcore + driver-model + IRQ + DMA + workqueue + slab +
#   sysfs + timer + spinlock + completion + printk + jiffies +
#   debugfs + hrtimer + platform_device + ...); 8 new at L64:
#   usb_calc_bus_time, usb_for_each_dev, usb_hcds_loaded DATA,
#   ehci_cf_port_reset_rwsem DATA, __platform_register_drivers,
#   platform_unregister_drivers, xen_dbgp_external_startup,
#   xen_dbgp_reset_prep.
#
#   42nd distro .ko to load. ehci-hcd's init_module body calls
#   __platform_register_drivers on an array of three ehci-platform
#   variants; none match in QEMU q35, so init falls through with
#   ret==0. Like xhci-hcd, the HCD probe only fires when a bridge
#   (ehci-pci) binds it to a PCIe device — which would need its own
#   batch (ehci-pci still has 14 UND missing).

. "$(dirname "$0")/_build_lock.sh"

set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf
LKM_DIR=tests/linux-modules
STAGED_KO="$LKM_DIR/ehci-hcd.ko"

KREL="$(uname -r)"
HOST_LIB="/lib/modules/${KREL}/kernel"
CANDIDATES=(
    "${HOST_LIB}/drivers/usb/host/ehci-hcd.ko"
    "${HOST_LIB}/drivers/usb/host/ehci-hcd.ko.xz"
)

picked=""
for c in "${CANDIDATES[@]}"; do
    if [ -f "$c" ]; then picked="$c"; break; fi
done

if [ -z "$picked" ]; then
    echo "L64: ehci-hcd.ko not present; skipping"
    exit 0
fi

echo "[test_l64_ehci_hcd] picked: $picked"

cleanup() {
    rm -f "$STAGED_KO"
    INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py \
        >/dev/null 2>&1 || true
}
trap cleanup EXIT

mkdir -p "$LKM_DIR"
case "$picked" in
    *.ko.xz) xz -dc "$picked" > "$STAGED_KO" ;;
    *.ko)    cp "$picked" "$STAGED_KO" ;;
esac
ls -l "$STAGED_KO"

UND_SYMS=$(nm -u "$STAGED_KO" 2>/dev/null | awk '{print $2}' | sort -u)
MISSING=""
for sym in $UND_SYMS; do
    if ! grep -rq "_add_export(\"${sym}\"" linux_abi/ 2>/dev/null; then
        MISSING+=" $sym"
    fi
done
echo "[test_l64_ehci_hcd] UND ($(echo "$UND_SYMS" | wc -w)):"
for s in $UND_SYMS; do echo "  $s"; done
echo "[test_l64_ehci_hcd] MISSING:"
if [ -n "$MISSING" ]; then for s in $MISSING; do echo "  - $s"; done; else echo "  (none - full coverage)"; fi

bash scripts/build_user.sh
bash scripts/build_modules.sh
INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py >/dev/null
python3 -m compiler.adder compile --target=x86_64-bare-metal init/main.ad -o "$ELF"

LOG="$(mktemp)"
set +e
(
    sleep 3
    printf 'insmod /lib/modules/6.12/ehci-hcd.ko\n'
    sleep 5
    printf 'exit\n'
    sleep 1
) | timeout 45s qemu-system-x86_64 \
    -kernel "$ELF" -smp 2 -nographic -no-reboot -m 256M \
    -monitor none -serial stdio > "$LOG" 2>&1
set -e

tail -n 40 "$LOG" || true

if grep -E -q "PANIC|panic:" "$LOG"; then
    echo "[test_l64_ehci_hcd] FAIL: kernel panic"
    exit 1
fi

INIT_OK=$(grep -cE "kmod_linux: init returned 0" "$LOG" || true)
INIT_OK=${INIT_OK:-0}
LIB_ONLY=$(grep -cE "kmod_linux: no init function" "$LOG" || true)
LIB_ONLY=${LIB_ONLY:-0}
INSMOD_FAIL=$(grep -cE "insmod: init_module failed" "$LOG" || true)
INSMOD_FAIL=${INSMOD_FAIL:-0}

echo "[test_l64_ehci_hcd] init_OK=$INIT_OK lib_only=$LIB_ONLY fail=$INSMOD_FAIL"

if [ "$INSMOD_FAIL" -ge 1 ]; then echo "[test_l64_ehci_hcd] FAIL"; exit 1; fi
if [ "$INIT_OK" -ge 1 ] || [ "$LIB_ONLY" -ge 1 ]; then
    echo "[test_l64_ehci_hcd] PASS: ehci-hcd.ko loaded"
    exit 0
fi
echo "[test_l64_ehci_hcd] FAIL: no PASS markers"
exit 1
