#!/usr/bin/env bash
# scripts/test_access_mode.sh — access(2) mode-bit R/W/X verification.
#
# Proves the access(2) handler (linux_abi/u_syscalls.ad _u_access) does a
# REAL R/W/X permission check against an ext4 file's mode bits — the bit a
# busybox PATH search (X_OK probe) or `test -x` relies on. The in-kernel
# access_mode_selftest() (gated on the cpio marker /etc/access-mode-test)
# stamps a few ext4 files with known modes (0664/0755/0444) on the live
# /ext mount, then drives SYS_access through the real Linux-ABI dispatch:
#   * F_OK on an existing file        -> 0
#   * R_OK / W_OK on the 0664 file    -> 0
#   * X_OK on the 0664 file (no x)    -> -EACCES
#   * X_OK on the 0755 file (x set)   -> 0
#   * W_OK on the 0444 file (no w)    -> -EACCES
#   * R_OK on the 0444 file           -> 0
#   * a non-existent path             -> -ENOENT
# The selftest does all the work, so the host just attaches a plain,
# empty ext4 scratch disk on virtio (a real superblock + writable mount).
#
# Boot path: a raw 64-bit Hamnix ELF will NOT boot under `qemu -kernel` on
# this host; the _kernel_iso.sh PATH shim (sourced by _build_lock.sh)
# transparently wraps the ELFCLASS64 kernel in a BIOS GRUB ISO, so the
# `-kernel "$ELF"` invocation below boots through the ISO shim.
#
# Pass marker:  [test_access_mode] PASS   (kernel prints [ACCESS_MODE] PASS)
# Fail marker:  [test_access_mode] FAIL

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

DISK=$(mktemp --suffix=.accmode.img)
LOG=${HAMNIX_ACCESS_MODE_LOG:-$(mktemp)}
trap 'rm -f "$DISK"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1 || true' EXIT

echo "[test_access_mode] (1/4) Mint a 1 KiB-block ext4 scratch image"
truncate -s 64M "$DISK"
"$MKFS" -F -q -b 1024 -t ext4 -L "HAMNIX_ACCMODE" -O '^has_journal' "$DISK" >/dev/null

echo "[test_access_mode] (2/4) Build userland + plant /etc/access-mode-test + /init"
bash scripts/build_user.sh >/dev/null
INIT_ELF="$HAMSH_ELF" ENABLE_ACCESS_MODE_TEST=1 \
    python3 scripts/build_initramfs.py >/dev/null

echo "[test_access_mode] (3/4) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

echo "[test_access_mode] (4/4) Boot QEMU with the ext4 scratch image"
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

echo "[test_access_mode] --- access mode self-test output ---"
grep -a -E "\[ACCESS_MODE\]" "$LOG" || true
echo "[test_access_mode] --- end ---"

fail=0

if grep -a -F -q "[ACCESS_MODE] FAIL" "$LOG"; then
    echo "[test_access_mode] FAIL: kernel self-test reported an internal failure" >&2
    grep -a -F "[ACCESS_MODE] FAIL" "$LOG" >&2 || true
    fail=1
fi

if ! grep -a -F -q "[ACCESS_MODE] PASS" "$LOG"; then
    echo "[test_access_mode] MISS: self-test PASS banner (expected '[ACCESS_MODE] PASS')" >&2
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_access_mode] --- full log ---"
    cat "$LOG"
    echo "[test_access_mode] FAIL (qemu rc=$rc)"
    exit 1
fi

echo "[test_access_mode] PASS — access(2) does a real R/W/X mode-bit check" \
     "on ext4 (qemu rc=$rc)"
