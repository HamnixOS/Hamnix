#!/usr/bin/env bash
# scripts/test_ehci_msc.sh — EHCI (USB 2.0) BULK mass-storage EXERCISE.
#
# Boots the hand-rolled drivers/usb/ehci.ad transfer engine against a
# QEMU-emulated USB stick attached to an EHCI (USB 2.0) host controller
# and proves the NEW bulk path works end to end:
#
#   EHCI enumerate (port reset -> SET_ADDRESS -> GET descriptors ->
#   SET_CONFIGURATION, locate bulk IN/OUT endpoints) -> bulk QH on the
#   async ring -> Bulk-Only Transport (CBW/CSW) -> SCSI INQUIRY +
#   READ CAPACITY -> SCSI READ(10) of sector 0 -> bytes match the tag
#   stamped into the test image.
#
# This is the EHCI parallel of test_usbms.sh (which proves the same BOT
# path over xHCI). EHCI previously had ONLY control + interrupt
# transfers; the bulk path added in drivers/usb/ehci.ad is what makes
# USB 2.0 mass storage possible on an EHCI controller.
#
# Marker: ENABLE_EHCI_MSC_TEST=1 plants /etc/ehci-msc-test so
# init/main.ad's ehci_msc_selftest() runs.
#
# PASS / FAIL channel: the `[ehci-msc] PASS` / `FAIL` marker line.

. "$(dirname "$0")/_build_lock.sh"

set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf
EHCI_MSC_TIMEOUT="${EHCI_MSC_TIMEOUT:-120}"
IMG=build/ehcimsc.img

# QEMU device-availability probe.
echo "[test_ehci_msc] (0/5) Probe QEMU for usb-ehci + usb-storage"
if ! qemu-system-x86_64 -device help 2>&1 | grep -q '"usb-ehci"'; then
    echo "[test_ehci_msc] SKIPPED — this QEMU build has no usb-ehci"
    exit 0
fi
if ! qemu-system-x86_64 -device help 2>&1 | grep -q '"usb-storage"'; then
    echo "[test_ehci_msc] SKIPPED — this QEMU build has no usb-storage"
    exit 0
fi
echo "[test_ehci_msc] OK: QEMU has usb-ehci + usb-storage"

echo "[test_ehci_msc] (1/5) Stamp a 16 MiB test USB image"
python3 - "$IMG" <<'PYEOF'
import sys, os
path = sys.argv[1]
os.makedirs(os.path.dirname(path), exist_ok=True)
size = 16 * 1024 * 1024
with open(path, "wb") as f:
    f.truncate(size)
    f.seek(0)
    f.write(b"EHCIUSB!")           # sector 0 tag the kernel matches
    f.seek(512)
    f.write(b"SECTOR01")           # sector 1 sentinel
print("[test_ehci_msc]   wrote", path, os.path.getsize(path), "bytes")
PYEOF

echo "[test_ehci_msc] (2/5) Build userland + modules"
bash scripts/build_user.sh >/dev/null
bash scripts/build_modules.sh >/dev/null

echo "[test_ehci_msc] (3/5) Build initramfs (ehci-msc-test ON)"
ENABLE_XHCI_KO=0 ENABLE_EHCI_MSC_TEST=1 INIT_ELF=build/user/init.elf \
    python3 scripts/build_initramfs.py >/dev/null

echo "[test_ehci_msc] (4/5) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

LOG="$(mktemp)"
# Restore the default initramfs at the end so subsequent tests don't
# inherit the marker.
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1 || true' EXIT

echo "[test_ehci_msc] (5/5) Boot QEMU with usb-ehci + usb-storage"
# The kernel is a true elf64-x86-64 higher-half image; QEMU's -kernel
# multiboot1 loader rejects 64-bit ELFs. Wrap it in a GRUB BIOS ISO and
# boot -cdrom. `-boot d` forces CD boot ahead of the usb-storage drive.
source "$PROJ_ROOT/scripts/_kernel_iso.sh"
KISO="$(kernel_iso "$ELF")"
set +e
timeout "${EHCI_MSC_TIMEOUT}s" qemu-system-x86_64 \
    -boot d -cdrom "$KISO" \
    -device usb-ehci,id=ehci \
    -drive if=none,id=stick,file="$IMG",format=raw \
    -device usb-storage,bus=ehci.0,drive=stick \
    -smp 2 -nographic -no-reboot -m 256M \
    -monitor none -serial stdio \
    > "$LOG" 2>&1 < /dev/null
rc=$?
set -e

echo "[test_ehci_msc] --- captured (ehci-msc) ---"
grep -aE '\[ehci-msc|\[ehci\] controller|bulk-in-ep|bulk-out-ep|READ CAPACITY|INQUIRY|device configured' "$LOG" | head -40 || true
echo "[test_ehci_msc] --- end ---"

if grep -aE -q "PANIC|panic:|TRAP:|BUG:" "$LOG"; then
    echo "[test_ehci_msc] FAIL: kernel panic / trap"
    tail -n 60 "$LOG"
    exit 1
fi

# PASS / FAIL channel — the READ(10) of sector 0 returned the tag.
if grep -aF -q "[ehci-msc] PASS" "$LOG"; then
    echo "[test_ehci_msc] PASS: EHCI bulk READ(10) of sector 0 returned the EHCIUSB tag"
    exit 0
fi

echo "[test_ehci_msc] FAIL: no [ehci-msc] PASS marker (qemu rc=$rc)"
grep -aE "\[ehci-msc\]" "$LOG" || true
tail -n 60 "$LOG"
exit 1
