#!/usr/bin/env bash
# scripts/test_squashfs.sh — squashfs read-only reader verification.
#
# squashfs is the compressed read-only image format real Linux
# liveUSBs use (Debian Live's live/filesystem.squashfs). fs/squashfs.ad
# parses it and exposes mount / lookup / read / readdir off a block
# device. This test bakes a small squashfs as /dev/ram1 and runs the
# kernel-side sqfs_smoke_test, which:
#   - mounts the squashfs superblock,
#   - lists the root directory (proves readdir),
#   - reads /hello.txt (proves a fragment-packed file read),
#   - reads /subdir/nested.txt (proves a path walk through a subdir).
#
# It runs the whole thing TWICE — once with a gzip-compressed image
# (compression id 1 -> zlib/inflate) and once with an xz-compressed
# image (id 4 -> lib/xz/xz.ad) — to prove BOTH decompress paths.
#
# The compressor is selected at image-build time via SQFS_COMP, so
# each pass regenerates the baked blob and rebuilds the kernel.

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf

# Ensure an initramfs blob exists so the kernel links (the default
# /init is fine — we only need the kernel-side smoke test to fire at
# boot, before userland).
if [ ! -f fs/initramfs_blob.S ]; then
    echo "[test_squashfs] building initramfs blob"
    python3 scripts/build_initramfs.py >/dev/null
fi

run_one() {
    local comp="$1"
    echo "[test_squashfs] ===== compressor: $comp ====="

    echo "[test_squashfs] (1/3) Bake squashfs blob ($comp) + disk images"
    SQFS_COMP="$comp" python3 scripts/build_diskimg.py | grep -i squashfs || true

    echo "[test_squashfs] (2/3) Rebuild kernel image"
    python3 -m compiler.adder compile \
        --target=x86_64-bare-metal \
        init/main.ad \
        -o "$ELF"

    echo "[test_squashfs] (3/3) Boot QEMU; run sqfs smoke test"
    local LOG
    LOG=$(mktemp)
    set +e
    timeout 40s qemu-system-x86_64 \
        -kernel "$ELF" \
        -smp 2 \
        -nographic \
        -no-reboot \
        -m 256M \
        -monitor none \
        -serial stdio \
        > "$LOG" 2>&1
    set -e

    echo "[test_squashfs] --- captured squashfs output ($comp) ---"
    grep -iE "squashfs|sqfs|ram1" "$LOG" || echo "(no squashfs lines)"
    echo "[test_squashfs] --- end output ---"

    local fail=0
    if grep -F -q "squashfs: smoke PASS" "$LOG"; then
        echo "[test_squashfs] OK ($comp): smoke PASS"
    else
        echo "[test_squashfs] MISS ($comp): 'squashfs: smoke PASS' absent"
        fail=1
    fi
    if grep -F -q "SQFS_HELLO_MARKER" "$LOG"; then
        echo "[test_squashfs] OK ($comp): /hello.txt read back"
    else
        echo "[test_squashfs] MISS ($comp): SQFS_HELLO_MARKER absent"
        fail=1
    fi
    if grep -F -q "SQFS_NESTED_MARKER" "$LOG"; then
        echo "[test_squashfs] OK ($comp): /subdir/nested.txt read back"
    else
        echo "[test_squashfs] MISS ($comp): SQFS_NESTED_MARKER absent"
        fail=1
    fi
    if grep -F -q "readme.txt" "$LOG"; then
        echo "[test_squashfs] OK ($comp): readdir listed readme.txt"
    else
        echo "[test_squashfs] MISS ($comp): readdir did not list readme.txt"
        fail=1
    fi
    rm -f "$LOG"
    if [ "$fail" -ne 0 ]; then
        echo "[test_squashfs] FAIL ($comp)"
        return 1
    fi
    echo "[test_squashfs] PASS ($comp)"
}

overall=0
run_one gzip || overall=1
run_one xz   || overall=1

# Restore the default gzip blob so a later build isn't left in xz state.
SQFS_COMP=gzip python3 scripts/build_diskimg.py >/dev/null

if [ "$overall" -ne 0 ]; then
    echo "[test_squashfs] OVERALL FAIL"
    exit 1
fi
echo "[test_squashfs] OVERALL PASS (gzip + xz)"
