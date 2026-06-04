#!/usr/bin/env bash
# scripts/test_fchmodat2.sh — fchmodat2(2) (nr 452) round-trip verification.
#
# Proves the Linux-ABI fchmodat2 syscall (linux_abi/u_fchmodat2.ad
# fchmodat2_handler, dispatched from linux_abi/u_syscalls.ad at nr 452) is a
# REAL flags-aware *at chmod over the SAME VFS resolve/open path that
# chmod/fchmodat already use — NOT an ENOSYS stub and NOT a flag-ignoring
# no-op. The in-kernel fchmodat2_selftest() (gated on the cpio marker
# /etc/fchmodat2-test, which is also the real file it chmods) runs the real
# checks:
#   (1) chmod a real path, flags=0 -> 0
#   (2) chmod with AT_SYMLINK_NOFOLLOW -> 0 (flag accepted)
#   (3) chmod a missing path -> -ENOENT (resolve is real)
#   (4) chmod with an unsupported flag bit -> -EINVAL (validated, not ignored)
#   (5) AT_EMPTY_PATH on a real open fd (NULL path and "" path) -> 0
#   (6) AT_EMPTY_PATH on a stale fd / AT_FDCWD -> -EBADF
# The selftest does all the work and needs NO extra disk.
#
# Boot path: a raw 64-bit Hamnix ELF will NOT boot under `qemu -kernel` on this
# host; the _kernel_iso.sh PATH shim (sourced by _build_lock.sh) transparently
# wraps the ELFCLASS64 kernel in a BIOS GRUB ISO, so the `-kernel "$ELF"`
# invocation below boots through the ISO shim.
#
# Pass marker:  [test_fchmodat2] PASS   (kernel prints [fchmodat2] PASS)
# Fail marker:  [test_fchmodat2] FAIL

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

export HAMNIX_BUILD_LOCK_TIMEOUT="${HAMNIX_BUILD_LOCK_TIMEOUT:-900}"

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf

LOG=${HAMNIX_FCHMODAT2_LOG:-$(mktemp)}
trap 'INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1 || true' EXIT

echo "[test_fchmodat2] (1/3) Build userland + plant /etc/fchmodat2-test + /init"
bash scripts/build_user.sh >/dev/null
INIT_ELF="$HAMSH_ELF" ENABLE_FCHMODAT2_TEST=1 \
    python3 scripts/build_initramfs.py >/dev/null

echo "[test_fchmodat2] (2/3) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

echo "[test_fchmodat2] (3/3) Boot QEMU (no extra disk needed)"
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

echo "[test_fchmodat2] --- fchmodat2 self-test output ---"
grep -a -E "\[FCHMODAT2\]|\[fchmodat2\]" "$LOG" || true
echo "[test_fchmodat2] --- end ---"

fail=0

if grep -a -F -q "[FCHMODAT2] FAIL" "$LOG"; then
    echo "[test_fchmodat2] FAIL: kernel self-test reported an internal failure" >&2
    grep -a -F "[FCHMODAT2] FAIL" "$LOG" >&2 || true
    fail=1
fi

if grep -a -F -q "[fchmodat2] self-test reported FAIL" "$LOG"; then
    echo "[test_fchmodat2] FAIL: fchmodat2_selftest returned failure" >&2
    fail=1
fi

if ! grep -a -F -q "[fchmodat2] PASS" "$LOG"; then
    echo "[test_fchmodat2] MISS: self-test PASS banner (expected '[fchmodat2] PASS')" >&2
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_fchmodat2] --- full log ---"
    cat "$LOG"
    echo "[test_fchmodat2] FAIL (qemu rc=$rc)"
    exit 1
fi

echo "[test_fchmodat2] PASS — fchmodat2 flags validated, AT_EMPTY_PATH-on-fd +" \
     "missing-path ENOENT round-trip over the VFS resolve/open path (qemu rc=$rc)"
