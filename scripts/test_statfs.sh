#!/usr/bin/env bash
# scripts/test_statfs.sh — statfs(2)/fstatfs(2) capacity verification.
#
# Proves the new Linux-ABI statfs(2)/fstatfs(2) handlers (linux_abi/
# u_syscalls.ad) report REAL filesystem capacity for df / statvfs-based
# tools. The in-kernel statfs_selftest() (gated on the cpio marker
# /etc/statfs-test) drives _u_statfs through the real Linux-ABI dispatch
# on the live ext4 mount (/ext) and the synthetic root (/), asserting a
# non-zero block size + total-block count and the EXT4 magic (the REAL
# superblock geometry), then drives _u_fstatfs on an open tmpfs fd
# (TMPFS magic) and a bad fd (-EBADF). The selftest does all the work, so
# the host only attaches a plain, empty ext4 scratch disk on virtio (so
# the ext4 leg has a real superblock to read).
#
# Boot path: a raw 64-bit Hamnix ELF will NOT boot under `qemu -kernel` on
# this host; the _kernel_iso.sh PATH shim (sourced by _build_lock.sh)
# transparently wraps the ELFCLASS64 kernel in a BIOS GRUB ISO, so the
# `-kernel "$ELF"` invocation below boots through the ISO shim.
#
# Pass marker:  [test_statfs] PASS   (kernel prints [STATFS] PASS)
# Fail marker:  [test_statfs] FAIL

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

DISK=$(mktemp --suffix=.statfs.img)
LOG=${HAMNIX_STATFS_LOG:-$(mktemp)}
trap 'rm -f "$DISK"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1 || true' EXIT

echo "[test_statfs] (1/4) Mint a 1 KiB-block ext4 scratch image"
truncate -s 64M "$DISK"
"$MKFS" -F -q -b 1024 -t ext4 -L "HAMNIX_STATFS" -O '^has_journal' "$DISK" >/dev/null

echo "[test_statfs] (2/4) Build userland + plant /etc/statfs-test + /init"
bash scripts/build_user.sh >/dev/null
INIT_ELF="$HAMSH_ELF" ENABLE_STATFS_TEST=1 \
    python3 scripts/build_initramfs.py >/dev/null

echo "[test_statfs] (3/4) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

echo "[test_statfs] (4/4) Boot QEMU with the ext4 scratch image"
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

echo "[test_statfs] --- statfs self-test output ---"
grep -a -E "\[STATFS\]" "$LOG" || true
echo "[test_statfs] --- end ---"

fail=0

if grep -a -F -q "[STATFS] FAIL" "$LOG"; then
    echo "[test_statfs] FAIL: kernel self-test reported an internal failure" >&2
    grep -a -F "[STATFS] FAIL" "$LOG" >&2 || true
    fail=1
fi

if ! grep -a -F -q "[STATFS] PASS" "$LOG"; then
    echo "[test_statfs] MISS: self-test PASS banner (expected '[STATFS] PASS')" >&2
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_statfs] --- full log ---"
    cat "$LOG"
    echo "[test_statfs] FAIL (qemu rc=$rc)"
    exit 1
fi

echo "[test_statfs] PASS — statfs/fstatfs report real ext4 + tmpfs capacity" \
     "for df (qemu rc=$rc)"
