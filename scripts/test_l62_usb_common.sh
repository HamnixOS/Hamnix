#!/usr/bin/env bash
# scripts/test_l62_usb_common.sh — L62 usb-common.ko load test.
#
# Goal:
#   Ship usb-common.ko (Linux's USB common helpers — the kernel module
#   that publishes usb_speed_string / usb_state_string /
#   usb_ep_type_string / usb_decode_interval, the usb_debug_root debugfs
#   dentry, and registers two LED triggers ("usb-host", "usb-gadget")).
#   L61 had patched the seven usb-common symbols that usbcore consumed
#   directly through the Linux-ABI table; L62 lets the real .ko load
#   alongside, exporting the same symbols natively. 13 UND total; 6
#   covered by L<=61, 7 new at L62 (in linux_abi/api_l62.ad).
#
#   The 7 new exports: __dev_fwnode_const, device_property_read_string,
#   fwnode_property_match_property_string, led_trigger_blink_oneshot,
#   led_trigger_register_simple, led_trigger_unregister_simple,
#   match_string.

. "$(dirname "$0")/_build_lock.sh"

set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf
LKM_DIR=tests/linux-modules
STAGED_KO="$LKM_DIR/usb-common.ko"

KREL="$(uname -r)"
HOST_LIB="/lib/modules/${KREL}/kernel"
CANDIDATES=(
    "${HOST_LIB}/drivers/usb/common/usb-common.ko"
    "${HOST_LIB}/drivers/usb/common/usb-common.ko.xz"
)

picked=""
for c in "${CANDIDATES[@]}"; do
    if [ -f "$c" ]; then picked="$c"; break; fi
done

if [ -z "$picked" ]; then
    echo "L62: usb-common.ko not present; skipping"
    exit 0
fi

echo "[test_l62_usb_common] picked: $picked"

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
echo "[test_l62_usb_common] UND ($(echo "$UND_SYMS" | wc -w)):"
for s in $UND_SYMS; do echo "  $s"; done
echo "[test_l62_usb_common] MISSING:"
if [ -n "$MISSING" ]; then for s in $MISSING; do echo "  - $s"; done; else echo "  (none - full coverage)"; fi

bash scripts/build_user.sh
bash scripts/build_modules.sh
INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py >/dev/null
python3 -m compiler.adder compile --target=x86_64-bare-metal init/main.ad -o "$ELF"

LOG="$(mktemp)"
set +e
(
    sleep 3
    printf 'insmod /lib/modules/6.12/usb-common.ko\n'
    sleep 5
    printf 'exit\n'
    sleep 1
) | timeout 45s qemu-system-x86_64 \
    -kernel "$ELF" -smp 2 -nographic -no-reboot -m 256M \
    -monitor none -serial stdio > "$LOG" 2>&1
set -e

tail -n 40 "$LOG" || true

if grep -E -q "PANIC|panic:" "$LOG"; then
    echo "[test_l62_usb_common] FAIL: kernel panic"
    exit 1
fi

INIT_OK=$(grep -cE "kmod_linux: init returned 0" "$LOG" || true)
INIT_OK=${INIT_OK:-0}
LIB_ONLY=$(grep -cE "kmod_linux: no init function" "$LOG" || true)
LIB_ONLY=${LIB_ONLY:-0}
INSMOD_FAIL=$(grep -cE "insmod: init_module failed" "$LOG" || true)
INSMOD_FAIL=${INSMOD_FAIL:-0}

echo "[test_l62_usb_common] init_OK=$INIT_OK lib_only=$LIB_ONLY fail=$INSMOD_FAIL"

if [ "$INSMOD_FAIL" -ge 1 ]; then echo "[test_l62_usb_common] FAIL"; exit 1; fi
if [ "$INIT_OK" -ge 1 ] || [ "$LIB_ONLY" -ge 1 ]; then
    echo "[test_l62_usb_common] PASS: usb-common.ko loaded"
    exit 0
fi
echo "[test_l62_usb_common] FAIL: no PASS markers"
exit 1
