#!/usr/bin/env bash
# scripts/test_process_vm.sh — process_vm_readv(2)/process_vm_writev(2)
# cross-address-space round-trip verification.
#
# Proves the Linux-ABI process_vm_readv/writev syscalls (linux_abi/u_process_vm.ad
# pvm_process_vm_readv / pvm_process_vm_writev, dispatched from
# linux_abi/u_syscalls.ad at nr 310/311) are backed by a REAL cross-address-space
# copy instead of returning ENOSYS or doing a same-process memcpy. The remote
# buffer is resolved by walking the REMOTE task's OWN page table (task_pml4 +
# uaccess_resolve), so the transfer crosses two distinct address spaces. The
# in-kernel process_vm_selftest() (gated on the cpio marker /etc/process-vm-test)
# runs the checks:
#   (1) build a real SECOND address space (a fresh task slot, distinct PML4) and
#       install a known page at a non-identity remote vaddr (vaddr != phys)
#   (2) process_vm_readv remote -> local asserts the pattern byte-exact
#   (3) process_vm_writev local -> remote, inspected in the remote frame
#   (4) bogus pid -> ESRCH; flags!=0 -> EINVAL; unmapped remote -> EFAULT;
#       short read stops at the page boundary; scatter/gather over two local
#       iovecs reassembles correctly
# The selftest does all the work and needs NO extra QEMU disk.
#
# Boot path: a raw 64-bit Hamnix ELF will NOT boot under `qemu -kernel` on this
# host; the _kernel_iso.sh PATH shim (sourced by _build_lock.sh) transparently
# wraps the ELFCLASS64 kernel in a BIOS GRUB ISO, so the `-kernel "$ELF"`
# invocation below boots through the ISO shim.
#
# Pass marker:  [test_process_vm] PASS   (kernel prints [process_vm] PASS)
# Fail marker:  [test_process_vm] FAIL

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

export HAMNIX_BUILD_LOCK_TIMEOUT="${HAMNIX_BUILD_LOCK_TIMEOUT:-900}"

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf

LOG=${HAMNIX_PROCESS_VM_LOG:-$(mktemp)}
trap 'INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1 || true' EXIT

echo "[test_process_vm] (1/3) Build userland + plant /etc/process-vm-test + /init"
bash scripts/build_user.sh >/dev/null
INIT_ELF="$HAMSH_ELF" ENABLE_PROCESS_VM_TEST=1 \
    python3 scripts/build_initramfs.py >/dev/null

echo "[test_process_vm] (2/3) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

echo "[test_process_vm] (3/3) Boot QEMU (no extra disk needed)"
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

echo "[test_process_vm] --- process_vm self-test output ---"
grep -a -E "\[PROCESS_VM\]|\[process_vm\]" "$LOG" || true
echo "[test_process_vm] --- end ---"

fail=0

if grep -a -F -q "[PROCESS_VM] FAIL" "$LOG"; then
    echo "[test_process_vm] FAIL: kernel self-test reported an internal failure" >&2
    grep -a -F "[PROCESS_VM] FAIL" "$LOG" >&2 || true
    fail=1
fi

if ! grep -a -F -q "[process_vm] PASS" "$LOG"; then
    echo "[test_process_vm] MISS: self-test PASS banner (expected '[process_vm] PASS')" >&2
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_process_vm] --- full log ---"
    cat "$LOG"
    echo "[test_process_vm] FAIL (qemu rc=$rc)"
    exit 1
fi

echo "[test_process_vm] PASS — process_vm_readv/writev cross-address-space" \
     "transfer through the remote task page-walk (qemu rc=$rc)"
