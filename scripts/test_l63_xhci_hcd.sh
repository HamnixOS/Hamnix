#!/usr/bin/env bash
# scripts/test_l63_xhci_hcd.sh — L63 xhci-hcd.ko load test.
#
# Goal:
#   Ship xhci-hcd.ko (Linux's USB 3.x host controller driver — the
#   kernel module implementing the eXtensible Host Controller
#   Interface, the modern replacement for ehci/ohci/uhci). xhci-hcd
#   sits just above usbcore on the USB stack; with xhci-pci or
#   xhci-plat-hcd binding it to real hardware below, xhci-hcd
#   manages every USB SuperSpeed (3.x) port and all USB 2/1.1 ports
#   on a modern x86 chipset. 156 UND total; 83 covered by L<=62
#   (usbcore + driver-model + IRQ + DMA + workqueue + slab + sysfs
#   + timer + spinlock + completion + printk + jiffies + gen_pool
#   + ACPI + PCI), 73 new at L63 across nine groups: bpf/trace
#   runtime (bpf_trace_run{1,2,3}, perf_trace_*, trace_event_*,
#   trace_seq_acquire, trace_handle_return, trace_print_symbols_seq,
#   trace_raw_output_prep, __trace_trigger_soft_disabled), radix_tree
#   (insert/lookup/delete/maybe_preload), platform_device
#   (alloc/add/add_resources/put/unregister), usbcore HCD/quirk
#   helpers (usb_hcd_*, usb_amd_*, usb_acpi_*,
#   usb_asmedia_modifyflowcontrol, usb_hub_clear_tt_buffer,
#   usb_root_hub_lost_power, usb_wakeup_notification, usb_hc_died,
#   usb_disabled, usb_disable_xhci_ports), DMA + kmalloc-cache-node
#   (dma_set_{mask,coherent_mask}, __kmalloc_{node,cache_node}_noprof),
#   seq_file / single_open helpers, scatterlist partial copy
#   (sg_pcopy_{from,to}_buffer), the two DATA exports
#   (__cpu_online_mask, pci_bus_type), and the misc batch
#   (cancel_delayed_work, complete_all, __const_udelay,
#   debugfs_create_regset32, device_create_managed_software_node,
#   __devm_add_action, dmi_get_system_info, iommu_get_domain_for_dev,
#   kstrtou16_from_user, param_ops_ullong, schedule_timeout_
#   uninterruptible, __SCT__preempt_schedule_notrace, vsnprintf).
#
#   38th distro .ko to load. Total exports after L63: 1190 + 73 =
#   1263 (under MAX_EXPORTS=2048).

. "$(dirname "$0")/_build_lock.sh"

set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf
LKM_DIR=tests/linux-modules
STAGED_KO="$LKM_DIR/xhci-hcd.ko"

KREL="$(uname -r)"
HOST_LIB="/lib/modules/${KREL}/kernel"
CANDIDATES=(
    "${HOST_LIB}/drivers/usb/host/xhci-hcd.ko"
    "${HOST_LIB}/drivers/usb/host/xhci-hcd.ko.xz"
)

picked=""
for c in "${CANDIDATES[@]}"; do
    if [ -f "$c" ]; then picked="$c"; break; fi
done

if [ -z "$picked" ]; then
    echo "L63: xhci-hcd.ko not present; skipping"
    exit 0
fi

echo "[test_l63_xhci_hcd] picked: $picked"

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
echo "[test_l63_xhci_hcd] UND ($(echo "$UND_SYMS" | wc -w)):"
for s in $UND_SYMS; do echo "  $s"; done
echo "[test_l63_xhci_hcd] MISSING:"
if [ -n "$MISSING" ]; then for s in $MISSING; do echo "  - $s"; done; else echo "  (none - full coverage)"; fi

bash scripts/build_user.sh
bash scripts/build_modules.sh
INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py >/dev/null
python3 -m compiler.adder compile --target=x86_64-bare-metal init/main.ad -o "$ELF"

LOG="$(mktemp)"
set +e
(
    sleep 3
    printf 'insmod /lib/modules/6.12/xhci-hcd.ko\n'
    sleep 5
    printf 'exit\n'
    sleep 1
) | timeout 45s qemu-system-x86_64 \
    -kernel "$ELF" -smp 2 -nographic -no-reboot -m 256M \
    -monitor none -serial stdio > "$LOG" 2>&1
set -e

tail -n 40 "$LOG" || true

if grep -E -q "PANIC|panic:" "$LOG"; then
    echo "[test_l63_xhci_hcd] FAIL: kernel panic"
    exit 1
fi

INIT_OK=$(grep -cE "kmod_linux: init returned 0" "$LOG" || true)
INIT_OK=${INIT_OK:-0}
LIB_ONLY=$(grep -cE "kmod_linux: no init function" "$LOG" || true)
LIB_ONLY=${LIB_ONLY:-0}
INSMOD_FAIL=$(grep -cE "insmod: init_module failed" "$LOG" || true)
INSMOD_FAIL=${INSMOD_FAIL:-0}

echo "[test_l63_xhci_hcd] init_OK=$INIT_OK lib_only=$LIB_ONLY fail=$INSMOD_FAIL"

if [ "$INSMOD_FAIL" -ge 1 ]; then echo "[test_l63_xhci_hcd] FAIL"; exit 1; fi
if [ "$INIT_OK" -ge 1 ] || [ "$LIB_ONLY" -ge 1 ]; then
    echo "[test_l63_xhci_hcd] PASS: xhci-hcd.ko loaded"
    exit 0
fi
echo "[test_l63_xhci_hcd] FAIL: no PASS markers"
exit 1
