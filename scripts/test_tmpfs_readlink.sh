#!/usr/bin/env bash
# scripts/test_tmpfs_readlink.sh — readlink(2)/readlinkat(2)-on-tmpfs
# symlink verification.
#
# Proves the Linux-ABI readlink(2)/readlinkat(2) handler (_u_readlinkat in
# linux_abi/u_syscalls.ad) consults the tmpfs symlink store. tmpfs now keeps
# a symlink's target string in-RAM (fs/tmpfs.ad); the in-kernel
# tmpfs_readlink_selftest() (gated on the cpio marker /etc/tmpfs-readlink-
# test) creates a tmpfs file plus a tmpfs symlink with a known target string,
# then drives SYS_readlink and SYS_readlinkat through the real Linux-ABI
# dispatch (linux_u_syscall_dispatch — the exact path a Debian/glibc binary
# takes) on the symlink and asserts: the returned byte count == the target
# length, the copied bytes == the target string, NO trailing NUL is written,
# truncation to a short bufsiz returns exactly bufsiz, and readlink on a
# non-symlink tmpfs file returns -EINVAL.
#
# tmpfs is RAM-backed, so — unlike the statfs/access self-tests — this needs
# NO disk image: nothing is attached on virtio.
#
# Boot path: a raw 64-bit Hamnix ELF will NOT boot under `qemu -kernel` on
# this host; the _kernel_iso.sh PATH shim (sourced by _build_lock.sh)
# transparently wraps the ELFCLASS64 kernel in a BIOS GRUB ISO, so the
# `-kernel "$ELF"` invocation below boots through the ISO shim.
#
# Pass marker:  [test_tmpfs_readlink] PASS   (kernel prints [TMPFS_READLINK] PASS)
# Fail marker:  [test_tmpfs_readlink] FAIL

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

export HAMNIX_BUILD_LOCK_TIMEOUT="${HAMNIX_BUILD_LOCK_TIMEOUT:-900}"

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf

LOG=${HAMNIX_TMPFS_READLINK_LOG:-$(mktemp)}
trap 'INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1 || true' EXIT

echo "[test_tmpfs_readlink] (1/3) Build userland + plant /etc/tmpfs-readlink-test + /init"
bash scripts/build_user.sh >/dev/null
INIT_ELF="$HAMSH_ELF" ENABLE_TMPFS_READLINK_TEST=1 \
    python3 scripts/build_initramfs.py >/dev/null

echo "[test_tmpfs_readlink] (2/3) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

echo "[test_tmpfs_readlink] (3/3) Boot QEMU (no disk image — pure tmpfs)"
set +e
timeout 180s qemu-system-x86_64 \
    -kernel "$ELF" \
    -smp 1 \
    -nographic \
    -no-reboot \
    -m 256M \
    -monitor none \
    -serial stdio \
    </dev/null > "$LOG" 2>&1
rc=$?
set -e

echo "[test_tmpfs_readlink] --- self-test output ---"
grep -a -E "\[TMPFS_READLINK\]" "$LOG" || true
echo "[test_tmpfs_readlink] --- end ---"

fail=0

if grep -a -F -q "[TMPFS_READLINK] FAIL" "$LOG"; then
    echo "[test_tmpfs_readlink] FAIL: kernel self-test reported an internal failure" >&2
    grep -a -F "[TMPFS_READLINK] FAIL" "$LOG" >&2 || true
    fail=1
fi

if ! grep -a -F -q "[TMPFS_READLINK] PASS" "$LOG"; then
    echo "[test_tmpfs_readlink] MISS: self-test PASS banner (expected '[TMPFS_READLINK] PASS')" >&2
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_tmpfs_readlink] --- full log ---"
    cat "$LOG"
    echo "[test_tmpfs_readlink] FAIL (qemu rc=$rc)"
    exit 1
fi

echo "[test_tmpfs_readlink] PASS — readlink/readlinkat resolve tmpfs symlinks" \
     "(qemu rc=$rc)"
