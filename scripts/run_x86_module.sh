#!/usr/bin/env bash
# Hamnix x86_64 kernel-module dev loop: build -> boot QEMU -> read serial.
#
# Builds a Hamnix kernel module, packs it into the busybox initramfs, boots
# the custom mitigations-off kernel under QEMU with -serial stdio, and
# asserts the module's printk output appeared. This closes the
# code -> build -> boot -> read -> iterate loop for the kernel-module target.
#
# Usage: run_x86_module.sh [module-dir]      (default: kernel-modules/hello)
#
# Env overrides:
#   PYNUX_KERNEL_DIR  kernel + busybox location  (default: ~/hamnix-kernel)
#   KDIR              kernel build tree          (default: $PYNUX_KERNEL_DIR/linux)
#   TIMEOUT           QEMU timeout in seconds    (default: 60)
#
# Exit codes (mirrors tests/qemu_runner.py):
#   0 - module loaded, expected output seen
#   1 - booted but expected output missing (test failure)
#   2 - execution error (missing kernel, QEMU not found, timeout, crash)
set -euo pipefail

PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODULE_DIR="${1:-kernel-modules/hello}"
PYNUX_KERNEL_DIR="${PYNUX_KERNEL_DIR:-$HOME/hamnix-kernel}"
KDIR="${KDIR:-$PYNUX_KERNEL_DIR/linux}"
TIMEOUT="${TIMEOUT:-60}"

BZIMAGE="$KDIR/arch/x86/boot/bzImage"
INITRAMFS="$PROJ_ROOT/build/initramfs.cpio.gz"

cd "$PROJ_ROOT"

# Install the qemu-system-x86_64 shim (PATH-prepended). It transparently
# wraps an ELFCLASS64 `-kernel` in a GRUB ISO and — relevant here —
# injects `-accel kvm` when /dev/kvm is usable, so this real-Linux
# bzImage boot also gets hardware acceleration. See scripts/_kernel_iso.sh.
# shellcheck source=_kernel_iso.sh
source "$PROJ_ROOT/scripts/_kernel_iso.sh"

# --- preflight --------------------------------------------------------------
if ! command -v qemu-system-x86_64 >/dev/null; then
    echo "[run] error: qemu-system-x86_64 not found (apt install qemu-system-x86)" >&2
    exit 2
fi
if [ ! -f "$BZIMAGE" ]; then
    echo "[run] error: kernel image not found: $BZIMAGE" >&2
    echo "[run] build it first: scripts/build_x86_kernel.sh" >&2
    exit 2
fi

# --- build the module -------------------------------------------------------
echo "[run] building module in $MODULE_DIR (KDIR=$KDIR)"
make -C "$MODULE_DIR" KDIR="$KDIR"

KO_FILES=("$MODULE_DIR"/*.ko)
if [ ! -e "${KO_FILES[0]}" ]; then
    echo "[run] error: no .ko produced in $MODULE_DIR" >&2
    exit 2
fi

# --- (re)pack the initramfs with the fresh module ---------------------------
echo "[run] packing initramfs"
"$PROJ_ROOT/scripts/make_initramfs.sh" "${KO_FILES[@]}"

# --- boot QEMU and capture serial -------------------------------------------
echo "[run] booting QEMU (timeout ${TIMEOUT}s)"
echo "---------------------------------------------------------------"
# console=ttyS0 keeps the kernel printing during boot (before our module
# loads). console=hamnix is parsed as a pending match — register_console
# enables our console when its name matches.
# Two -serial slots so the guest sees ttyS0 (stdio = console) AND
# ttyS1 (null backend, but the 16550A hardware on 0x2f8/IRQ 3 is now
# wired into QEMU — needed by M4.1's UART-RX IRQ test on COM2).
# virtio-blk-pci attached so M4.2's driver has a device to probe; the
# /init script handles unbinding the kernel's built-in virtio_blk so
# our Hamnix driver can claim it.
DISKIMG="$PROJ_ROOT/build/hamnixblk.img"
DISK_ARGS=""
if [ -f "$DISKIMG" ]; then
    DISK_ARGS="-drive file=$DISKIMG,if=none,id=hamnixblk,format=raw \
               -device virtio-blk-pci,drive=hamnixblk"
fi
# Always wire a virtio-net device with SLIRP user-mode networking so the
# M4.3b Hamnix virtio-net driver has a device to probe. Other modules
# pay a few-line boot tax but no functional cost.
NET_ARGS="-netdev user,id=hamnixnet -device virtio-net-pci,netdev=hamnixnet"
OUTPUT="$(timeout "$TIMEOUT" qemu-system-x86_64 \
    -kernel "$BZIMAGE" \
    -initrd "$INITRAMFS" \
    -append "console=ttyS0 console=hamnix panic=-1 nokaslr" \
    -nographic -monitor none \
    -serial stdio -serial null \
    $DISK_ARGS \
    $NET_ARGS \
    -no-reboot -m 256M \
    < /dev/null 2>&1 | tee /dev/stderr)" || true
echo "---------------------------------------------------------------"

# --- assert expected output -------------------------------------------------
# Per-module expectations live in <MODULE_DIR>/expected.txt — one literal
# string per line. The runner asserts every line is present in the captured
# serial output. Missing file = no module-specific assertions (just check
# the boot completed).
fail=0
check() {
    if grep -qF "$1" <<<"$OUTPUT"; then
        echo "[run]   ok: '$1'"
    else
        echo "[run]   MISSING: '$1'"
        fail=1
    fi
}

if ! grep -qF "[PYNUX-DONE]" <<<"$OUTPUT" && ! grep -qF "[PYNUX-M1-DONE]" <<<"$OUTPUT"; then
    echo "[run] FAIL: boot did not complete (no done sentinel)"
    exit 2
fi

EXPECTED="$MODULE_DIR/expected.txt"
if [ -f "$EXPECTED" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
        [ -z "$line" ] && continue
        case "$line" in \#*) continue ;; esac
        check "$line"
    done < "$EXPECTED"
else
    echo "[run]   (no expected.txt; checked boot sentinel only)"
fi

if [ "$fail" -ne 0 ]; then
    echo "[run] FAIL: expected module output missing"
    exit 1
fi
echo "[run] PASS: module loaded and produced expected output"
exit 0
