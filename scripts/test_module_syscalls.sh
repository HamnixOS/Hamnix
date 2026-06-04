#!/usr/bin/env bash
# scripts/test_module_syscalls.sh -- init_module/finit_module/delete_module
# for the Linux ABI.
#
# Real Linux insmod/modprobe/rmmod (running in Hamnix's distro namespace,
# is_linux_userspace != 0) load and unload .ko modules via three syscalls:
#   init_module(175)   : load from an in-memory .ko image
#   finit_module(313)  : load from an open fd (the modern insmod/modprobe path)
#   delete_module(176) : unload by module name
# All three handlers live in linux_abi/u_syscalls.ad (_u_init_module /
# _u_finit_module / _u_delete_module) and are wired into the central Linux-ABI
# dispatcher (linux_u_syscall_dispatch) at their standard x86_64 numbers. They
# marshal the user-supplied (or fd-backed) bytes into Hamnix's EXISTING
# in-kernel module loader (kmod_linux_load / kmod_linux_unload); delete_module
# resolves a name to its loaded slot via kmod_linux_find_by_name.
#
# This boots the kernel once with /etc/kmodsys-test planted
# (ENABLE_KMODSYS_TEST=1); init/main.ad's gate (boot:37.kmodsys) calls
# kmod_syscall_selftest() (linux_abi/u_syscalls.ad), which drives, in boot
# context, the SAME dispatch path a Linux binary hits:
#
#   * init_module(NULL,0,NULL)        -> -EINVAL  (rejected before the loader)
#   * init_module(ptr, oversize, _)   -> -ENOMEM  (image-size cap fires)
#   * finit_module(-1, NULL, 0)       -> -EBADF   (bad fd rejected up front)
#   * delete_module("no_such",0)      -> -ENOENT  (name->slot resolver miss)
#
# The positive full-load round-trip (finit_module of a real distro .ko then
# delete_module) is covered by scripts/test_l30_distro_module.sh, which stages
# a real .ko; this test stays hermetic by asserting the wired error/lookup
# paths, which need no .ko image on the host.
#
# Pass marker:  [test_module_syscalls] PASS
# Fail marker:  [test_module_syscalls] FAIL

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

export HAMNIX_BUILD_LOCK_TIMEOUT=900

ELF=build/hamnix-kernel.elf

echo "[test_module_syscalls] (1/3) Build userland (init)"
bash scripts/build_user.sh >/dev/null

echo "[test_module_syscalls] (2/3) Build kernel with /etc/kmodsys-test marker"
INIT_ELF=build/user/init.elf ENABLE_KMODSYS_TEST=1 \
    python3 scripts/build_initramfs.py >/dev/null
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1 || true' EXIT

echo "[test_module_syscalls] (3/3) Boot QEMU and run the kmod-syscall self-test"
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

echo "[test_module_syscalls] --- kmod-syscall self-test output ---"
grep -aE "\[kmodsys\]" "$LOG" || true
echo "[test_module_syscalls] --- end ---"

fail=0

if [ "$rc" -ne 0 ] && [ "$rc" -ne 124 ]; then
    echo "[test_module_syscalls] FAIL: qemu exited rc=$rc" >&2
    fail=1
fi

if grep -aqF "[kmodsys] FAIL" "$LOG"; then
    echo "[test_module_syscalls] FAIL: kernel self-test reported a failure" >&2
    grep -aF "[kmodsys] FAIL" "$LOG" | head -5 || true
    fail=1
fi

# Exactly "[kmodsys] PASS" on its own line (after an optional printk
# timestamp prefix) only when every assertion held.
if grep -aqE '(^|\] )\[kmodsys\] PASS$' "$LOG"; then
    echo "[test_module_syscalls] PASS: overall self-test PASS banner"
else
    echo "[test_module_syscalls] FAIL: overall self-test PASS banner missing" >&2
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_module_syscalls] FAIL"
    exit 1
fi

echo "[test_module_syscalls] PASS -- init_module/finit_module/delete_module" \
     "are wired into the Linux-ABI dispatch and route into the in-kernel" \
     "module loader (error + name->slot lookup paths verified)"
