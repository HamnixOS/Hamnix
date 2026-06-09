#!/usr/bin/env bash
# scripts/test_linkat.sh — symlink(2)/link(2)/utimensat(2) Linux-ABI
# verification.
#
# Proves the newly-wired Linux-ABI symlink/link/timestamp family
# (_u_symlink/_u_symlinkat/_u_link/_u_linkat/_u_utimensat in
# linux_abi/u_syscalls.ad) drives the real in-kernel dispatch
# (linux_u_syscall_dispatch — the exact path a Debian/glibc binary takes)
# against the live tmpfs backend. The in-kernel linkat_selftest() (gated on
# the cpio marker /etc/linkat-test) asserts:
#   * SYS_symlink creates a tmpfs symlink whose target round-trips via
#     SYS_readlink byte-for-byte (the `ln -s` contract),
#   * SYS_symlinkat does the same via the AT_FDCWD entry,
#   * SYS_link creates a tmpfs hardlink whose new name reads the SAME data
#     byte as the original (the `ln` contract),
#   * a cross-backend SYS_link (/tmp -> /ext) returns -EXDEV (the Plan 9
#     file-server boundary),
#   * SYS_utimensat returns 0 on an existing path, -ENOENT on a missing
#     path, and -EFAULT on a NULL path pointer.
#
# tmpfs is RAM-backed, so — unlike the statfs/access self-tests — this needs
# NO disk image: nothing is attached on virtio.
#
# Boot path: a raw 64-bit Hamnix ELF will NOT boot under `qemu -kernel` on
# this host; the _kernel_iso.sh PATH shim (sourced by _build_lock.sh)
# transparently wraps the ELFCLASS64 kernel in a BIOS GRUB ISO, so the
# `-kernel "$ELF"` invocation below boots through the ISO shim.
#
# Pass marker:  [test_linkat] PASS   (kernel prints [LINKAT] PASS)
# Fail marker:  [test_linkat] FAIL

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

export HAMNIX_BUILD_LOCK_TIMEOUT="${HAMNIX_BUILD_LOCK_TIMEOUT:-900}"

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf

LOG=${HAMNIX_LINKAT_LOG:-$(mktemp)}
trap 'INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1 || true' EXIT

echo "[test_linkat] (1/3) Build userland + plant /etc/linkat-test + /init"
bash scripts/build_user.sh >/dev/null
INIT_ELF="$HAMSH_ELF" ENABLE_LINKAT_TEST=1 \
    python3 scripts/build_initramfs.py >/dev/null

echo "[test_linkat] (2/3) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

echo "[test_linkat] (3/3) Boot QEMU (no disk image — pure tmpfs)"
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

echo "[test_linkat] --- self-test output ---"
grep -a -E "\[LINKAT\]" "$LOG" || true
echo "[test_linkat] --- end ---"

fail=0

if grep -a -F -q "[LINKAT] FAIL" "$LOG"; then
    echo "[test_linkat] FAIL: kernel self-test reported an internal failure" >&2
    grep -a -F "[LINKAT] FAIL" "$LOG" >&2 || true
    fail=1
fi

if ! grep -a -F -q "[LINKAT] PASS" "$LOG"; then
    echo "[test_linkat] MISS: self-test PASS banner (expected '[LINKAT] PASS')" >&2
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_linkat] --- full log ---"
    cat "$LOG"
    echo "[test_linkat] FAIL (qemu rc=$rc)"
    exit 1
fi

echo "[test_linkat] PASS — symlink/link/utimensat work through Linux-ABI dispatch" \
     "(qemu rc=$rc)"
