#!/usr/bin/env bash
# scripts/test_mempolicy.sh — NUMA mempolicy round-trip verification.
#
# Proves the Linux-ABI NUMA mempolicy syscalls (linux_abi/u_mempolicy.ad
# umpol_set_mempolicy / umpol_get_mempolicy / umpol_mbind, dispatched from
# linux_abi/u_syscalls.ad at nr 238/239/237) are backed by a REAL per-task
# {mode, nodemask} store (keyed by task slot, lazily defaulting an unseen task
# to MPOL_DEFAULT) and HONEST single-node validation, instead of returning
# ENOSYS or ignoring their arguments. The in-kernel mempolicy_selftest()
# (gated on the cpio marker /etc/mempolicy-test) runs the real checks:
#   (1) set_mempolicy(BIND,{0}); get_mempolicy round-trips mode+mask
#   (2) set_mempolicy(INTERLEAVE,{0}); get_mempolicy re-asserts
#   (3) set_mempolicy(BIND,{node 1}) -> EINVAL (no such node)
#   (4) mmap a real range, mbind(BIND,{0}) -> 0
#   (5) mbind(BIND,{node 1}) -> EINVAL; mbind over unmapped range -> EFAULT
#   (6) get_mempolicy(MPOL_F_MEMS_ALLOWED) mask has node 0; NODE|ADDR -> 0
# Then init/main.ad reads /sys/devices/system/node/online through the real VFS
# path and asserts "0". The selftest does all the work and needs NO extra disk.
#
# Boot path: a raw 64-bit Hamnix ELF will NOT boot under `qemu -kernel` on this
# host; the _kernel_iso.sh PATH shim (sourced by _build_lock.sh) transparently
# wraps the ELFCLASS64 kernel in a BIOS GRUB ISO, so the `-kernel "$ELF"`
# invocation below boots through the ISO shim.
#
# Pass marker:  [test_mempolicy] PASS   (kernel prints [mempolicy] PASS)
# Fail marker:  [test_mempolicy] FAIL

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

export HAMNIX_BUILD_LOCK_TIMEOUT="${HAMNIX_BUILD_LOCK_TIMEOUT:-900}"

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf

LOG=${HAMNIX_MEMPOLICY_LOG:-$(mktemp)}
trap 'INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1 || true' EXIT

echo "[test_mempolicy] (1/3) Build userland + plant /etc/mempolicy-test + /init"
bash scripts/build_user.sh >/dev/null
INIT_ELF="$HAMSH_ELF" ENABLE_MEMPOLICY_TEST=1 \
    python3 scripts/build_initramfs.py >/dev/null

echo "[test_mempolicy] (2/3) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

echo "[test_mempolicy] (3/3) Boot QEMU (no extra disk needed)"
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

echo "[test_mempolicy] --- mempolicy self-test output ---"
grep -a -E "\[MEMPOLICY\]|\[mempolicy\]" "$LOG" || true
echo "[test_mempolicy] --- end ---"

fail=0

if grep -a -F -q "[MEMPOLICY] FAIL" "$LOG"; then
    echo "[test_mempolicy] FAIL: kernel self-test reported an internal failure" >&2
    grep -a -F "[MEMPOLICY] FAIL" "$LOG" >&2 || true
    fail=1
fi

if grep -a -F -q "[mempolicy] self-test reported FAIL" "$LOG"; then
    echo "[test_mempolicy] FAIL: mempolicy_selftest returned failure" >&2
    fail=1
fi

if ! grep -a -F -q "[mempolicy] PASS" "$LOG"; then
    echo "[test_mempolicy] MISS: self-test PASS banner (expected '[mempolicy] PASS')" >&2
    fail=1
fi

if ! grep -a -F -q "[MEMPOLICY] PASS /sys/.../node/online == '0'" "$LOG"; then
    echo "[test_mempolicy] MISS: sysfs node/online assertion" >&2
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_mempolicy] --- full log ---"
    cat "$LOG"
    echo "[test_mempolicy] FAIL (qemu rc=$rc)"
    exit 1
fi

echo "[test_mempolicy] PASS — set/get_mempolicy + mbind round-trip through the" \
     "per-task policy store, /sys NUMA node served (qemu rc=$rc)"
