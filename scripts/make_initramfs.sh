#!/usr/bin/env bash
# Build the minimal busybox initramfs for the Pynux M1 QEMU dev loop.
#
# The initramfs auto-loads the kernel module, dumps dmesg, unloads it, and
# powers off — so QEMU output is fully scriptable. The /init script prints
# a "[PASS] m1-hello" line that the existing tests/qemu_runner.py output
# scraper already recognizes, plus a "[PYNUX-M1-DONE]" sentinel.
#
# Usage: make_initramfs.sh <module.ko> [<module.ko> ...]
#
# Output: build/initramfs.cpio.gz
#
# Env overrides:
#   BUSYBOX_VERSION   busybox release to build static  (default: 1.36.1)
#   PYNUX_KERNEL_DIR  cache dir for the busybox build  (default: ~/pynux-kernel)
set -euo pipefail

if [ "$#" -lt 1 ]; then
    echo "usage: make_initramfs.sh <module.ko> [<module.ko> ...]" >&2
    exit 2
fi

BUSYBOX_VERSION="${BUSYBOX_VERSION:-1.36.1}"
PYNUX_KERNEL_DIR="${PYNUX_KERNEL_DIR:-$HOME/pynux-kernel}"
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$PROJ_ROOT/build"
BB_SRC="$PYNUX_KERNEL_DIR/busybox-${BUSYBOX_VERSION}"
BB_BIN="$BB_SRC/busybox"

# Resolve module paths to absolute up front — we cd into the busybox build
# dir below and the relative paths from the caller would otherwise break.
KO_ABS=()
for ko in "$@"; do
    KO_ABS+=("$(readlink -f "$ko")")
done

mkdir -p "$PYNUX_KERNEL_DIR" "$BUILD_DIR"

# --- static busybox (cached) ------------------------------------------------
if [ ! -x "$BB_BIN" ]; then
    echo "[initramfs] building static busybox $BUSYBOX_VERSION"
    cd "$PYNUX_KERNEL_DIR"
    if [ ! -d "$BB_SRC" ]; then
        curl -fLO "https://busybox.net/downloads/busybox-${BUSYBOX_VERSION}.tar.bz2"
        tar -xf "busybox-${BUSYBOX_VERSION}.tar.bz2"
        rm -f "busybox-${BUSYBOX_VERSION}.tar.bz2"
    fi
    cd "$BB_SRC"
    make defconfig >/dev/null
    # Static link: the initramfs has no shared libraries.
    # Busybox has no scripts/config helper or olddefconfig target — edit
    # .config directly and let `make` consume it.
    sed -i 's/^# CONFIG_STATIC is not set/CONFIG_STATIC=y/' .config
    sed -i 's/^CONFIG_TC=y/# CONFIG_TC is not set/' .config  # avoid libtirpc dep
    yes "" | make oldconfig >/dev/null 2>&1 || true
    make -j"$(nproc)" >/dev/null
else
    echo "[initramfs] reusing cached busybox at $BB_BIN"
fi

# --- assemble the rootfs tree ----------------------------------------------
ROOT="$(mktemp -d)"
trap 'rm -rf "$ROOT"' EXIT

mkdir -p "$ROOT"/{bin,sbin,proc,sys,dev}
cp "$BB_BIN" "$ROOT/bin/busybox"
ln -s busybox "$ROOT/bin/sh"

for ko in "${KO_ABS[@]}"; do
    cp "$ko" "$ROOT/$(basename "$ko")"
done

cat > "$ROOT/init" <<'INIT'
#!/bin/sh
/bin/busybox --install -s /bin
mount -t proc proc /proc
mount -t sysfs sysfs /sys

echo "[PYNUX] loading kernel module(s)"
# If a Pynux virtio-blk module is about to load, unbind the kernel's
# built-in virtio_blk first so our driver can claim the device.
if ls /m4_virtio_blk.ko >/dev/null 2>&1; then
    for d in /sys/bus/virtio/drivers/virtio_blk/virtio*; do
        [ -e "$d" ] || continue
        name=$(basename "$d")
        echo "[PYNUX] unbinding $name from kernel virtio_blk"
        echo "$name" > /sys/bus/virtio/drivers/virtio_blk/unbind
    done
fi
if ls /m4_virtio_net.ko >/dev/null 2>&1; then
    for d in /sys/bus/virtio/drivers/virtio_net/virtio*; do
        [ -e "$d" ] || continue
        name=$(basename "$d")
        echo "[PYNUX] unbinding $name from kernel virtio_net"
        echo "$name" > /sys/bus/virtio/drivers/virtio_net/unbind
    done
fi
for ko in /*.ko; do
    echo "[PYNUX] insmod $ko"
    insmod "$ko"
done

echo "[PYNUX] --- dmesg tail ---"
dmesg | tail -n 20
echo "[PYNUX] --- end dmesg ---"

echo "[PYNUX] --- /proc/consoles ---"
cat /proc/consoles
echo "[PYNUX] --- end consoles ---"

if [ -e /proc/pynux/state ]; then
    echo "[PYNUX] --- /proc/pynux/state ---"
    cat /proc/pynux/state
    echo "[PYNUX] --- end /proc/pynux/state ---"
fi

echo "[PYNUX] --- /proc/partitions ---"
cat /proc/partitions
echo "[PYNUX] --- end /proc/partitions ---"

if ls /m11_debugfs.ko >/dev/null 2>&1; then
    mount -t debugfs none /sys/kernel/debug 2>&1 | head -1
    if [ -e /sys/kernel/debug/pynux/counter ]; then
        initial=$(cat /sys/kernel/debug/pynux/counter)
        echo "[PYNUX] dfs initial = $initial"
        echo 123 > /sys/kernel/debug/pynux/counter
        echo "[PYNUX] dfs after write = $(cat /sys/kernel/debug/pynux/counter)"
    fi
fi

if ls /m5_netfilter.ko >/dev/null 2>&1; then
    echo "[PYNUX] --- exercise netfilter hook ---"
    ifconfig eth0 10.0.2.15 up 2>&1 | head -2
    ping -c 2 -W 1 10.0.2.2 2>&1 | grep -E "transmitted|received" | head -1
    echo "[PYNUX] --- end netfilter ---"
fi

if ls /m8_netdev.ko >/dev/null 2>&1; then
    echo "[PYNUX] --- m8 netdev ---"
    # Pynux device gets the next free ethN slot after eth0=virtio-net.
    ifconfig eth1 192.168.99.1 netmask 255.255.255.0 up 2>&1 | head -2
    ifconfig eth1 2>&1 | head -3
    echo "[PYNUX] --- end netdev ---"
fi

if [ -d /sys/pynux ]; then
    echo "[PYNUX] --- /sys/pynux/info ---"
    cat /sys/pynux/info
    echo "[PYNUX] --- end /sys/pynux/info ---"
fi

if grep -qE '^[ 0-9]*241 pynurand$' /proc/devices 2>/dev/null; then
    echo "[PYNUX] --- exercise /dev/pynurand ---"
    mknod /dev/pynurand c 241 0
    bytes=$(dd if=/dev/pynurand bs=8 count=1 2>/dev/null | wc -c)
    if [ "$bytes" = "8" ]; then
        echo "[PYNUX] random ok"
    else
        echo "[PYNUX] random FAILED (got $bytes bytes)"
    fi
    rm -f /dev/pynurand
fi

if grep -qE '^[ 0-9]*242 pynuxzero$' /proc/devices 2>/dev/null; then
    echo "[PYNUX] --- exercise /dev/pynuxzero ---"
    mknod /dev/pynuxzero c 242 0
    nonzero=$(dd if=/dev/pynuxzero bs=1024 count=1 2>/dev/null | tr -d '\0' | wc -c)
    if [ "$nonzero" = "0" ]; then
        echo "[PYNUX] zero ok"
    else
        echo "[PYNUX] zero FAILED ($nonzero non-zero bytes)"
    fi
    rm -f /dev/pynuxzero
fi

if grep -qE '^[ 0-9]*240 pynux$' /proc/devices 2>/dev/null; then
    echo "[PYNUX] --- exercise /dev/pynux ---"
    mknod /dev/pynux c 240 0
    echo "[PYNUX] cat /dev/pynux:"
    cat /dev/pynux
    echo "[PYNUX] echo > /dev/pynux:"
    echo "testdata" > /dev/pynux && echo "[PYNUX] write ok"
    rm -f /dev/pynux
    echo "[PYNUX] --- end /dev/pynux ---"
fi

if grep -q pynuxfs /proc/filesystems 2>/dev/null; then
    echo "[PYNUX] --- exercise pynuxfs ---"
    mkdir -p /mnt/pynuxfs
    if mount -t pynuxfs none /mnt/pynuxfs; then
        echo "[PYNUX] mount ok"

        # File create + write + read.
        if echo "hello from pynuxfs" > /mnt/pynuxfs/greeting; then
            echo "[PYNUX] write ok"
        else
            echo "[PYNUX] write FAILED"
        fi
        if [ -f /mnt/pynuxfs/greeting ]; then
            echo "[PYNUX] file exists"
        fi
        read_back=$(cat /mnt/pynuxfs/greeting 2>/dev/null)
        if [ "$read_back" = "hello from pynuxfs" ]; then
            echo "[PYNUX] read ok: $read_back"
        else
            echo "[PYNUX] read FAILED: got '$read_back'"
        fi

        # Directory create + remove.
        if mkdir /mnt/pynuxfs/subdir; then
            echo "[PYNUX] mkdir ok"
        else
            echo "[PYNUX] mkdir FAILED"
        fi
        echo "[PYNUX] ls /mnt/pynuxfs:"
        ls -la /mnt/pynuxfs

        # Cleanup.
        rm /mnt/pynuxfs/greeting && echo "[PYNUX] rm ok"
        rmdir /mnt/pynuxfs/subdir && echo "[PYNUX] rmdir ok"

        umount /mnt/pynuxfs && echo "[PYNUX] umount ok"
    else
        echo "[PYNUX] mount FAILED"
    fi
    echo "[PYNUX] --- end exercise pynuxfs ---"
fi

for ko in /*.ko; do
    name=$(basename "$ko" .ko)
    echo "[PYNUX] rmmod $name"
    rmmod "$name"
done

echo "[PYNUX-DONE]"
poweroff -f
INIT
chmod +x "$ROOT/init"

# --- pack -------------------------------------------------------------------
OUT="$BUILD_DIR/initramfs.cpio.gz"
( cd "$ROOT" && find . -print0 | cpio --null -o -H newc 2>/dev/null ) \
    | gzip -9 > "$OUT"

echo "[initramfs] wrote $OUT"
