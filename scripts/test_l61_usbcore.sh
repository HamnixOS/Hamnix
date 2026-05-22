#!/usr/bin/env bash
# scripts/test_l61_usbcore.sh — L61 usbcore.ko load test.
#
# Goal:
#   Ship usbcore.ko (Linux's USB stack foundation — the kernel module
#   that registers the "usb" bus type, the usb_device + usb_interface
#   classes, the usbfs character device, the hub thread, and the
#   per-device sysfs surface). 309 UND symbols total; 112 of those
#   are already covered by L<=60, 197 are new at L61 and live in
#   linux_abi/api_l61.ad.
#
#   usbcore depends on usb-common.ko but our loader doesn't ingest
#   sibling .ko ksymtabs yet — the seven symbols usbcore consumes
#   from usb-common (usb_speed_string, usb_state_string,
#   usb_ep_type_string, usb_decode_interval, usb_led_activity,
#   usb_hcd_amd_remote_wakeup_quirk, usb_debug_root DATA) are
#   shimmed at the Linux-ABI level instead.
#
#   This is the 35th distro module to load (after the L60 batch of 5
#   at 34 — nf_nat.ko / xt_nat.ko / xt_conntrack.ko / nls_ascii.ko /
#   nls_utf8.ko). Lands the device-model / sysfs-groups / pm_runtime /
#   DMA-pool / kobject_uevent / component-framework surface — a whole
#   new subsystem floor that future HCD + USB-class modules build on.
#
#   MAX_EXPORTS bumped 1024 -> 2048 to absorb the 197 new rows (943
#   used after L60 + 197 = 1140; tucks under the new 2048 ceiling).

. "$(dirname "$0")/_build_lock.sh"

set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf
LKM_DIR=tests/linux-modules
STAGED_KO="$LKM_DIR/usbcore.ko"

KREL="$(uname -r)"
HOST_LIB="/lib/modules/${KREL}/kernel"
CANDIDATES=(
    "${HOST_LIB}/drivers/usb/core/usbcore.ko"
    "${HOST_LIB}/drivers/usb/core/usbcore.ko.xz"
)

picked=""
for c in "${CANDIDATES[@]}"; do
    if [ -f "$c" ]; then picked="$c"; break; fi
done

if [ -z "$picked" ]; then
    echo "L61: usbcore.ko not present; skipping"
    exit 0
fi

echo "[test_l61_usbcore] picked: $picked"

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
echo "[test_l61_usbcore] UND ($(echo "$UND_SYMS" | wc -w)):"
for s in $UND_SYMS; do echo "  $s"; done
echo "[test_l61_usbcore] MISSING:"
if [ -n "$MISSING" ]; then for s in $MISSING; do echo "  - $s"; done; else echo "  (none - full coverage)"; fi

bash scripts/build_user.sh
bash scripts/build_modules.sh
INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py >/dev/null
python3 -m compiler.adder compile --target=x86_64-bare-metal init/main.ad -o "$ELF"

LOG="$(mktemp)"
set +e
(
    sleep 3
    printf 'insmod /lib/modules/6.12/usbcore.ko\n'
    sleep 5
    printf 'exit\n'
    sleep 1
) | timeout 45s qemu-system-x86_64 \
    -kernel "$ELF" -smp 2 -nographic -no-reboot -m 256M \
    -monitor none -serial stdio > "$LOG" 2>&1
set -e

tail -n 40 "$LOG" || true

if grep -E -q "PANIC|panic:" "$LOG"; then
    echo "[test_l61_usbcore] FAIL: kernel panic"
    exit 1
fi

INIT_OK=$(grep -cE "kmod_linux: init returned 0" "$LOG" || true)
INIT_OK=${INIT_OK:-0}
LIB_ONLY=$(grep -cE "kmod_linux: no init function" "$LOG" || true)
LIB_ONLY=${LIB_ONLY:-0}
INSMOD_FAIL=$(grep -cE "insmod: init_module failed" "$LOG" || true)
INSMOD_FAIL=${INSMOD_FAIL:-0}

echo "[test_l61_usbcore] init_OK=$INIT_OK lib_only=$LIB_ONLY fail=$INSMOD_FAIL"

if [ "$INSMOD_FAIL" -ge 1 ]; then echo "[test_l61_usbcore] FAIL"; exit 1; fi
if [ "$INIT_OK" -ge 1 ] || [ "$LIB_ONLY" -ge 1 ]; then
    echo "[test_l61_usbcore] PASS: usbcore.ko loaded"
    exit 0
fi
echo "[test_l61_usbcore] FAIL: no PASS markers"
exit 1
