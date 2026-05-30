#!/usr/bin/env bash
# scripts/test_img_usb_boot.sh — ACCEPTANCE GATE for ROOT-ON-USB.
#
# The real-hardware scenario this proves (an Intel NUC booting a Hamnix
# .img flashed to a USB stick): UEFI firmware launches the kernel off the
# ESP, but the ext4 root lives on the SAME USB stick — reachable ONLY
# through the xHCI + Bulk-Only-Transport stack, NOT virtio-blk/AHCI/NVMe.
#
# This test attaches build/hamnix.img as a USB MASS-STORAGE device on a
# qemu-xhci controller under OVMF, with NO virtio/AHCI/NVMe disk attached,
# and proves the cpio-less ext4-root path end to end OVER USB:
#
#   OVMF firmware
#     -> reads GPT off the usb-storage device, finds the ESP (FAT)
#     -> launches \EFI\BOOT\BOOTX64.EFI (native PE/COFF stub)
#     -> stub loads \hamnix-kernel.elf off the ESP and jumps to the kernel
#     -> kernel brings up xHCI (xhci_init_force), enumerates the BOT
#        mass-storage device, registers /dev/blk/sd0 BEFORE the ext4 scan
#     -> ext4-magic scan finds 0xEF53 on sd0, reads .hamnix-roots, binds
#        #sysroot at /, ELF-loads /init OFF EXT4 (on the USB stick)
#     -> /init execs /bin/hamsh /etc/rc.boot (both off ext4) -> shell
#
# Asserts, IN ORDER:
#   1. kernel banner              ("Hamnix kernel booting")
#   2. sd0 enumerated off USB     ("/dev/blk/sd0 ready")
#   3. ext4 magic found on sd0    ("[rootfs] ext4 magic on slot")
#   4. shell-ready marker         ("handing off to interactive shell")
#   5. a typed command resolves OFF EXT4: `ls /bin` lists the native
#      toolset AND there is ZERO "command not found".
#
# SKIPS CLEANLY (exit 0) when /dev/kvm or OVMF firmware is unavailable,
# or when this QEMU build lacks qemu-xhci / usb-storage — exactly like
# scripts/test_img_uefi_boot.sh and scripts/test_usbms.sh do.
#
# Env overrides:
#   HAMNIX_IMG         image path                (default: build/hamnix.img)
#   OVMF_FD            OVMF firmware path        (default: auto-resolved)
#   SHELL_BOOT_WAIT    seconds to wait for the   (default: 90)
#                      interactive-prompt marker
#   HAMNIX_SKIP_BUILD  1 = reuse existing image  (default: rebuild)

set -uo pipefail

PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

# shellcheck source=_build_lock.sh
source "$PROJ_ROOT/scripts/_build_lock.sh"

HAMNIX_IMG="${HAMNIX_IMG:-build/hamnix.img}"
SHELL_BOOT_WAIT="${SHELL_BOOT_WAIT:-90}"
KERNEL_BANNER="Hamnix kernel booting"
SD0_MARKER="/dev/blk/sd0 ready"
EXT4_SCAN_MARKER="[rootfs] ext4 magic on slot"
# rc.boot.full's final line before the interactive REPL.
PROMPT_MARKER="handing off to interactive shell"

# --- environment gates (skip cleanly) ---------------------------------
if [ ! -e /dev/kvm ]; then
    echo "[test_img_usb] SKIP: /dev/kvm absent (KVM required; boot too slow without it)" >&2
    exit 0
fi

if ! qemu-system-x86_64 -device help 2>&1 | grep -q '"qemu-xhci"'; then
    echo "[test_img_usb] SKIP: this QEMU build has no qemu-xhci" >&2
    exit 0
fi
if ! qemu-system-x86_64 -device help 2>&1 | grep -q '"usb-storage"'; then
    echo "[test_img_usb] SKIP: this QEMU build has no usb-storage" >&2
    exit 0
fi

# OVMF resolution: prefer the Debian-style single-file /usr/share/ovmf/
# OVMF.fd; fall back to the split /usr/share/OVMF/OVMF_CODE*.fd packaging.
OVMF_FD="${OVMF_FD:-}"
if [ -z "$OVMF_FD" ]; then
    if [ -f /usr/share/ovmf/OVMF.fd ]; then
        OVMF_FD=/usr/share/ovmf/OVMF.fd
    elif [ -f /usr/share/OVMF/OVMF_CODE.fd ]; then
        OVMF_FD=/usr/share/OVMF/OVMF_CODE.fd
    elif [ -f /usr/share/OVMF/OVMF_CODE_4M.fd ]; then
        OVMF_FD=/usr/share/OVMF/OVMF_CODE_4M.fd
    fi
fi
if [ -z "$OVMF_FD" ] || [ ! -f "$OVMF_FD" ]; then
    echo "[test_img_usb] SKIP: OVMF firmware not found (tried /usr/share/ovmf/OVMF.fd and /usr/share/OVMF/OVMF_CODE*.fd; apt install ovmf)" >&2
    exit 0
fi

# --- build the image --------------------------------------------------
if [ "${HAMNIX_SKIP_BUILD:-0}" != "1" ]; then
    echo "[test_img_usb] building disk image via build_img.sh"
    rm -f "$HAMNIX_IMG"
    bash "$PROJ_ROOT/scripts/build_img.sh"
fi
if [ ! -f "$HAMNIX_IMG" ]; then
    echo "[test_img_usb] FAIL: $HAMNIX_IMG missing after build_img.sh." >&2
    exit 1
fi

IMG_BYTES=$(stat -c%s "$HAMNIX_IMG")
echo "[test_img_usb] image size: ${IMG_BYTES} bytes ($(( IMG_BYTES / 1024 / 1024 )) MiB)"

# OVMF persists UEFI variables back into the firmware file, so it needs a
# writable copy. Copy the image too so a re-run starts pristine.
OVMF_RW=$(mktemp --tmpdir hamnix-img-usb.ovmf.XXXXXX.fd)
IMG_RW=$(mktemp --tmpdir hamnix-img-usb.disk.XXXXXX.img)
LOG=$(mktemp --tmpdir hamnix-img-usb.XXXXXX.log)
INFIFO=$(mktemp --tmpdir -u hamnix-img-usb-in.XXXXXX)
cp "$OVMF_FD" "$OVMF_RW"
cp "$HAMNIX_IMG" "$IMG_RW"
mkfifo "$INFIFO"

cleanup() {
    [ -n "${QEMU_PID:-}" ] && kill "$QEMU_PID" 2>/dev/null
    rm -f "$OVMF_RW" "$IMG_RW" "$INFIFO"
}
trap cleanup EXIT

exec 4<>"$INFIFO"
exec 3>"$INFIFO"

# Boot the image as a USB MASS-STORAGE device on an xHCI controller, with
# NO virtio/AHCI/NVMe disk attached — this is THE root-on-USB scenario.
qemu-system-x86_64 \
    -enable-kvm -cpu host \
    -bios "$OVMF_RW" \
    -device qemu-xhci,id=xhci \
    -drive if=none,format=raw,file="$IMG_RW",id=usbstick \
    -device usb-storage,bus=xhci.0,drive=usbstick \
    -m 1G \
    -nographic -no-reboot -monitor none \
    -serial stdio \
    <&4 > "$LOG" 2>&1 &
QEMU_PID=$!

# --- wait for the interactive prompt ----------------------------------
echo "[test_img_usb] waiting up to ${SHELL_BOOT_WAIT}s for prompt marker..."
booted=0
for _ in $(seq 1 "$SHELL_BOOT_WAIT"); do
    if grep -a -q "$PROMPT_MARKER" "$LOG"; then
        booted=1
        break
    fi
    if ! kill -0 "$QEMU_PID" 2>/dev/null; then
        echo "[test_img_usb] FAIL: qemu exited before reaching the prompt." >&2
        echo "----- serial log tail -----" >&2
        tail -80 "$LOG" >&2
        exit 1
    fi
    sleep 1
done

if [ "$booted" -ne 1 ]; then
    echo "[test_img_usb] FAIL: prompt marker '$PROMPT_MARKER' not seen in ${SHELL_BOOT_WAIT}s." >&2
    echo "----- serial log tail -----" >&2
    tail -80 "$LOG" >&2
    exit 1
fi
echo "[test_img_usb] prompt reached; letting rc.boot background jobs drain."
# rc.boot spawns detached background jobs (ntp, motd, etc.) that emit
# into the SAME serial stream right as the interactive readline opens.
# USB reads are slower than virtio, so give those a moment to self-reap
# before typing — otherwise the first keystroke of the first command
# races the still-printing rc.boot output and gets mangled.
sleep 6
echo "[test_img_usb] typing commands at the shell."

type_cmd() {
    printf '%s\n' "$1" >&3
    sleep 6
}

type_cmd "echo HAMNIX_USB_REPL_OK"     # proves echo + the REPL live
type_cmd "ls /bin"                     # native toolset must list OFF EXT4
type_cmd "echo HAMNIX_USB_DONE_99"

sleep 3
kill "$QEMU_PID" 2>/dev/null
wait "$QEMU_PID" 2>/dev/null
exec 3>&-
exec 4>&-

# --- assertions -------------------------------------------------------
fail=0

# 1. Kernel banner (proves the EFI stub loaded + jumped into the kernel).
if grep -a -q "$KERNEL_BANNER" "$LOG"; then
    echo "[test_img_usb] PASS: kernel banner ('$KERNEL_BANNER') present."
else
    echo "[test_img_usb] FAIL: kernel banner ('$KERNEL_BANNER') NOT present — EFI stub did not reach the kernel." >&2
    fail=1
fi

# 2. sd0 enumerated off the USB stick (the whole point — virtio/AHCI/NVMe
#    are absent, so the ONLY block device is the USB-attached sd0).
if grep -a -q -F "$SD0_MARKER" "$LOG"; then
    echo "[test_img_usb] PASS: /dev/blk/sd0 enumerated off the USB mass-storage device."
else
    echo "[test_img_usb] FAIL: sd0 not enumerated off USB ('$SD0_MARKER' absent) — xHCI/BOT bring-up did not register the stick." >&2
    fail=1
fi

# 3. ext4 magic found on a block device by the root scan (sd0 is the only
#    one), proving the cpio-less ext4 root was discovered OVER USB.
if grep -a -q -F "$EXT4_SCAN_MARKER" "$LOG"; then
    echo "[test_img_usb] PASS: ext4 superblock magic found by the root scan (off USB sd0)."
else
    echo "[test_img_usb] FAIL: ext4 magic not found by the root scan ('$EXT4_SCAN_MARKER' absent) — root never mounted off USB." >&2
    fail=1
fi

# 4. Shell-ready marker.
if grep -a -q "$PROMPT_MARKER" "$LOG"; then
    echo "[test_img_usb] PASS: shell-ready marker ('$PROMPT_MARKER') present."
else
    echo "[test_img_usb] FAIL: shell-ready marker ('$PROMPT_MARKER') NOT present." >&2
    fail=1
fi

# 5a. REPL alive.
if grep -a -q -E '^HAMNIX_USB_REPL_OK' "$LOG"; then
    echo "[test_img_usb] PASS: echo marker round-tripped (REPL alive)."
else
    echo "[test_img_usb] FAIL: echo marker not echoed back (REPL dead)." >&2
    fail=1
fi

# 5b. THE KEYSTONE: zero 'command not found'. With the toolset on the
#     USB ext4 and the kernel-bound #sysroot at /, every typed command
#     MUST resolve off the partition. Any 'command not found' means the
#     root-on-USB path is broken.
if grep -a -q "command not found" "$LOG"; then
    echo "[test_img_usb] FAIL: 'command not found' present — commands do NOT resolve off the USB ext4 root:" >&2
    grep -a "command not found" "$LOG" >&2
    fail=1
else
    echo "[test_img_usb] PASS (KEYSTONE): zero 'command not found' — commands resolve off the USB ext4 root."
fi

# 5c. `ls /bin` actually listed native tools off ext4.
hits=0
for tool in whoami xargs uname uptime wget which; do
    if grep -a -q -E "(^|[[:space:]])${tool}([[:space:]]|\$)" "$LOG"; then
        hits=$((hits + 1))
    fi
done
if [ "$hits" -ge 4 ]; then
    echo "[test_img_usb] PASS: ls /bin listed the native toolset off the USB ext4 ($hits/6 probe tools present)."
else
    echo "[test_img_usb] FAIL: ls /bin did not list the native toolset ($hits/6 probe tools) — USB ext4 /bin not resolving." >&2
    fail=1
fi

if [ "$fail" -eq 0 ]; then
    echo "[test_img_usb] PASS"
    rm -f "$LOG"
    exit 0
fi

# Distinguish the two failure shapes so CI output is self-explanatory:
#
#   * USB-READ stage (assertions 1..4): kernel boots off the ESP, xHCI +
#     BOT bring-up registers sd0 BEFORE the ext4 scan, the ext4 root is
#     discovered over USB, and the shell is reached. This is the part
#     this change set delivers, and it MUST hold.
#
#   * REPL/SPAWN stage (assertions 5a..5c): typing external commands at
#     the live shell. Both historical USB-only failures here are now FIXED:
#       - "command not found" for EVERY command was an xHCI Link-TRB
#         cycle-bit bug (the Link TRB's cycle was set once at ring init and
#         never refreshed on producer wrap, so the controller parked on the
#         Link the SECOND time a bulk ring wrapped — wedging every block
#         read past ~127 transfers, which only USB hit because its rings are
#         busier). Fixed in drivers/usb/xhci.ad (_xhci_ring_set_link_cycle).
#       - a stray leading byte on the FIRST command ("aecho ...") was
#         pre-prompt serial input (firmware/line noise) still draining into
#         the kernel RX FIFO as the REPL opened. Fixed by a getty-style
#         session-start input flush (drivers/tty/serial/early_8250.ad
#         uart_rx_flush_stale + a short bounded drain in hamsh ed_readline).
#     This block is now dead unless a regression reopens one of those.
if grep -a -q "$KERNEL_BANNER" "$LOG" \
   && grep -a -q -F "$SD0_MARKER" "$LOG" \
   && grep -a -q -F "$EXT4_SCAN_MARKER" "$LOG" \
   && grep -a -q "$PROMPT_MARKER" "$LOG"; then
    echo "[test_img_usb] ===================================================" >&2
    echo "[test_img_usb] USB-READ stage PASSED: kernel + xHCI/BOT + ext4 root" >&2
    echo "[test_img_usb]   discovery + shell handoff all work OVER USB." >&2
    echo "[test_img_usb] REPL/SPAWN stage BLOCKED: repeated rfork() under the" >&2
    echo "[test_img_usb]   USB-boot config kills forked children before they" >&2
    echo "[test_img_usb]   run (exit 127). This is a fork/COW defect, NOT a USB" >&2
    echo "[test_img_usb]   block-I/O defect — the same image passes 6/6 over" >&2
    echo "[test_img_usb]   virtio (test_img_uefi_boot.sh)." >&2
    echo "[test_img_usb] ===================================================" >&2
fi
echo "[test_img_usb] FAIL (serial log: $LOG)" >&2
exit 1
