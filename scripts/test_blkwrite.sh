#!/usr/bin/env bash
# scripts/test_blkwrite.sh - M16.60 verification.
#
# The kernel runs a block-write smoke test at boot, exercising
# blk_write_sectors → blk_read_sectors round-trip on whichever
# block device is attached. The pattern goes write → read-back →
# byte-compare → restore-original. This script boots the kernel
# in two configurations to verify both backends:
#
#   1. virtio-blk (vda) via -drive build/ext4.img — exercises the
#      VIRTIO_BLK_T_OUT request type end-to-end.
#   2. brd (ram0) when no -drive is passed — exercises the
#      memcpy-into-backing-region write path on the baked image.
#
# A successful test prints "blk: write smoke test PASS"; any
# byte mismatch or driver error prints "FAIL @offset=N".

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf

echo "[test_blkwrite] (1/3) Regenerate disk images"
python3 scripts/build_diskimg.py >/dev/null

echo "[test_blkwrite] (2/3) Rebuild kernel image"
bash scripts/build_user.sh >/dev/null
bash scripts/build_modules.sh >/dev/null
python3 scripts/build_initramfs.py >/dev/null
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

run_qemu() {
    local label="$1"; shift
    local log=$(mktemp)
    set +e
    timeout 8s qemu-system-x86_64 \
        -kernel "$ELF" \
        "$@" \
        -smp 2 -nographic -no-reboot -m 256M -monitor none -serial stdio \
        > "$log" 2>&1 < /dev/null
    set -e
    if grep -F -q "blk: write smoke test PASS" "$log"; then
        echo "[test_blkwrite] OK: $label"
        rm -f "$log"
        return 0
    fi
    echo "[test_blkwrite] FAIL ($label) — captured output:"
    cat "$log"
    rm -f "$log"
    return 1
}

echo "[test_blkwrite] (3/3) Boot variants"
fail=0
# virtio-blk (vda) path against the ext4 image
run_qemu "virtio-blk write round-trip (vda + ext4.img)" \
    -drive file=build/ext4.img,if=virtio,format=raw \
    || fail=1
# brd (ram0) path against the baked FAT image
run_qemu "brd write round-trip (ram0 + baked FAT)" \
    || fail=1

if [ "$fail" -ne 0 ]; then
    echo "[test_blkwrite] FAIL"
    exit 1
fi
echo "[test_blkwrite] PASS"
