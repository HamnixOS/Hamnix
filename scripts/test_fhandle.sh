#!/usr/bin/env bash
# scripts/test_fhandle.sh — name_to_handle_at(2)/open_by_handle_at(2)
# (x86_64 nr 303/304) file-handle round-trip verification.
#
# Proves the Linux-ABI file-handle syscalls (linux_abi/u_fhandle.ad
# ufh_name_to_handle_at / ufh_open_by_handle_at, dispatched from
# linux_abi/u_syscalls.ad at nr 303/304) really encode a PATH into an
# opaque, stable struct file_handle and then re-open the SAME underlying
# inode purely from that handle (no path). The handle blob carries the
# file's stable backing identity (fs marker + cpio index / ext4 inode num),
# and a kernel handle registry maps the embedded cookie back to the resolved
# path so the re-open travels the normal vfs_open route. The in-kernel
# fhandle_selftest() (gated on the cpio marker /etc/fhandle-test) runs:
#   (1) open the known file normally, read its first bytes, note its inode
#   (2) name_to_handle_at(path) -> a tagged struct file_handle + mount_id
#   (3) open_by_handle_at(handle) -> a NEW fd (no path) with the SAME inode
#       and IDENTICAL bytes
#   (4) too-small handle_bytes -> EOVERFLOW + required size reported
#   (5) corrupt handle -> EINVAL; stale cookie -> ESTALE
# The selftest does all the work and needs NO extra QEMU disk.
#
# Boot path: a raw 64-bit Hamnix ELF will NOT boot under `qemu -kernel` on
# this host; the _kernel_iso.sh PATH shim (sourced by _build_lock.sh) wraps
# the ELFCLASS64 kernel in a BIOS GRUB ISO, so `-kernel "$ELF"` boots via it.
#
# Pass marker:  [test_fhandle] PASS   (kernel prints [fhandle] PASS)
# Fail marker:  [test_fhandle] FAIL

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

export HAMNIX_BUILD_LOCK_TIMEOUT="${HAMNIX_BUILD_LOCK_TIMEOUT:-900}"

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf

LOG=${HAMNIX_FHANDLE_LOG:-$(mktemp)}
trap 'INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1 || true' EXIT

echo "[test_fhandle] (1/3) Build userland + plant /etc/fhandle-test + /init"
bash scripts/build_user.sh >/dev/null
INIT_ELF="$HAMSH_ELF" ENABLE_FHANDLE_TEST=1 \
    python3 scripts/build_initramfs.py >/dev/null

echo "[test_fhandle] (2/3) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

echo "[test_fhandle] (3/3) Boot QEMU (no extra disk needed)"
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

echo "[test_fhandle] --- fhandle self-test output ---"
grep -a -E "\[FHANDLE\]|\[fhandle\]" "$LOG" || true
echo "[test_fhandle] --- end ---"

fail=0

if grep -a -F -q "[FHANDLE] FAIL" "$LOG"; then
    echo "[test_fhandle] FAIL: kernel self-test reported an internal failure" >&2
    grep -a -F "[FHANDLE] FAIL" "$LOG" >&2 || true
    fail=1
fi

if ! grep -a -F -q "[fhandle] PASS" "$LOG"; then
    echo "[test_fhandle] MISS: self-test PASS banner (expected '[fhandle] PASS')" >&2
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_fhandle] --- full log ---"
    cat "$LOG"
    echo "[test_fhandle] FAIL (qemu rc=$rc)"
    exit 1
fi

echo "[test_fhandle] PASS — name_to_handle_at encodes a path to an opaque" \
     "handle and open_by_handle_at reopens the SAME inode (qemu rc=$rc)"
