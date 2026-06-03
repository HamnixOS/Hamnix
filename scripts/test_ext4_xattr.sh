#!/usr/bin/env bash
# scripts/test_ext4_xattr.sh — ext4 extended attributes (xattr) + POSIX ACL.
#
# Proves the ext4 xattr path: the in-kernel ext4_xattr_selftest() (gated on
# the cpio marker /etc/ext4xattr-test) sets a "user." attribute on a live
# ext4 inode, reads it back (in-inode region, magic 0xEA020000 at
# 128 + i_extra_isize), lists it, and decodes a POSIX ACL value. The
# selftest does all the work, so the host only attaches a plain empty ext4
# scratch disk on virtio (default inode_size 256 leaves room for in-inode
# xattrs).
#
# Boot path: a raw 64-bit Hamnix ELF will NOT boot under `qemu -kernel` on
# this host; the _kernel_iso.sh PATH shim (sourced by _build_lock.sh)
# transparently wraps the ELFCLASS64 kernel in a BIOS GRUB ISO.
#
# Pass marker:  [ext4-xattr] PASS
# Fail marker:  [ext4-xattr] FAIL

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

export HAMNIX_BUILD_LOCK_TIMEOUT="${HAMNIX_BUILD_LOCK_TIMEOUT:-900}"

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf

_which() {
    local name="$1"
    if command -v "$name" >/dev/null 2>&1; then command -v "$name"; return 0; fi
    for prefix in /sbin /usr/sbin /usr/local/sbin; do
        if [ -x "$prefix/$name" ]; then echo "$prefix/$name"; return 0; fi
    done
    echo "$0: required tool '$name' not found" >&2
    return 1
}
MKFS="$(_which mkfs.ext4)"

DISK=$(mktemp --suffix=.ext4xattr.img)
LOG=$(mktemp)
trap 'rm -f "$LOG" "$DISK"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1 || true' EXIT

echo "[test_ext4_xattr] (1/4) Mint a 1 KiB-block ext4 scratch image"
truncate -s 64M "$DISK"
"$MKFS" -F -q -b 1024 -I 256 -t ext4 -L "HAMNIX_XATTR" -O '^has_journal' "$DISK" >/dev/null

echo "[test_ext4_xattr] (2/4) Build userland + plant /etc/ext4xattr-test + /init"
bash scripts/build_user.sh >/dev/null
INIT_ELF="$HAMSH_ELF" ENABLE_EXT4XATTR_TEST=1 \
    python3 scripts/build_initramfs.py >/dev/null

echo "[test_ext4_xattr] (3/4) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

echo "[test_ext4_xattr] (4/4) Boot QEMU with the ext4 scratch image"
set +e
timeout 180s qemu-system-x86_64 \
    -kernel "$ELF" \
    -drive file="$DISK",if=virtio,format=raw \
    -smp 1 \
    -nographic \
    -no-reboot \
    -m 256M \
    -monitor none \
    -serial stdio \
    </dev/null > "$LOG" 2>&1
rc=$?
set -e

echo "[test_ext4_xattr] --- ext4-xattr self-test output ---"
grep -a -E "\[ext4-xattr\]" "$LOG" || true
echo "[test_ext4_xattr] --- end ---"

fail=0

# Treat a virtio-blk superblock-read flake (host CPU starvation under load)
# as INFRA, not a code failure — re-run in a quiet window for authority.
if grep -aqE "read failed status=255|failed to read superblock" "$LOG"; then
    echo "[test_ext4_xattr] WARN: virtio-blk read flake detected — re-run in a quiet window" >&2
fi

if grep -a -F -q "[ext4-xattr] FAIL" "$LOG"; then
    echo "[test_ext4_xattr] FAIL: kernel self-test reported an internal failure" >&2
    grep -a -F "[ext4-xattr] FAIL" "$LOG" >&2 || true
    fail=1
fi

if ! grep -a -F -q "[ext4-xattr] PASS" "$LOG"; then
    echo "[test_ext4_xattr] MISS: self-test PASS banner (expected '[ext4-xattr] PASS')" >&2
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_ext4_xattr] --- full log ---"
    cat "$LOG"
    echo "[test_ext4_xattr] FAIL (qemu rc=$rc)"
    exit 1
fi

echo "[test_ext4_xattr] PASS — ext4 in-inode xattr set/get/list + POSIX ACL" \
     "decode work on a live ext4 mount (qemu rc=$rc)"
