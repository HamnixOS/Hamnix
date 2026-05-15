#!/usr/bin/env bash
# Fetch and build the custom x86_64 Linux kernel for the Pynux M1 dev loop.
#
# Produces a bzImage with mitigations off (see x86_kernel_config.sh) that
# scripts/run_x86_module.sh boots under QEMU. This is a one-time setup step
# (incremental rebuilds afterwards are fast).
#
# Env overrides:
#   KERNEL_VERSION  kernel.org stable version      (default: 6.12.48)
#   PYNUX_KERNEL_DIR  where to put the source tree  (default: ~/pynux-kernel)
#
# Build dependencies (Debian): build-essential flex bison libelf-dev
# libssl-dev bc. Install them first if `make` complains.
set -euo pipefail

KERNEL_VERSION="${KERNEL_VERSION:-6.12.48}"
PYNUX_KERNEL_DIR="${PYNUX_KERNEL_DIR:-$HOME/pynux-kernel}"
KSRC="$PYNUX_KERNEL_DIR/linux"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

TARBALL="linux-${KERNEL_VERSION}.tar.xz"
MAJOR="${KERNEL_VERSION%%.*}"
URL="https://cdn.kernel.org/pub/linux/kernel/v${MAJOR}.x/${TARBALL}"

mkdir -p "$PYNUX_KERNEL_DIR"

if [ ! -d "$KSRC" ]; then
    echo "[kernel] fetching $TARBALL"
    cd "$PYNUX_KERNEL_DIR"
    curl -fLO "$URL"
    echo "[kernel] extracting"
    tar -xf "$TARBALL"
    mv "linux-${KERNEL_VERSION}" linux
    rm -f "$TARBALL"
else
    echo "[kernel] reusing existing source tree at $KSRC"
fi

"$SCRIPT_DIR/x86_kernel_config.sh" "$KSRC"

echo "[kernel] building bzImage + modules (-j$(nproc)) — this takes ~10-25 min first time"
echo "[kernel] (modules build is required: it generates Module.symvers, which"
echo "[kernel]  modpost needs to resolve symbols for out-of-tree modules)"
cd "$KSRC"
make -j"$(nproc)" bzImage modules

BZIMAGE="$KSRC/arch/x86/boot/bzImage"
echo
echo "[kernel] done."
echo "  bzImage: $BZIMAGE"
echo "  KDIR:    $KSRC   (pass this to kernel-modules/*/Makefile)"
