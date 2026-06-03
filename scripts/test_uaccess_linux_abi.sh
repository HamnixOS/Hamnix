#!/usr/bin/env bash
# scripts/test_uaccess_linux_abi.sh — #163 FOLLOW-UP: prove the converted
# LINUX-ABI syscall handlers copy their assembled structs/buffers out
# THROUGH the copy_to_user translation rather than raw-dereferencing the
# user pointer.
#
# mm/uaccess.ad::uaccess_smoke_test proves the copy_to_user PRIMITIVE
# translates a vaddr != phys mapping; arch/x86/kernel/syscall.ad::
# uaccess_syscall_test proves the converted NATIVE SYS_GETCWD handler does
# too. This test covers the LINUX-ABI side: at boot, init/main.ad runs
# linux_abi_uaccess_translate_test() (linux_abi/u_syscalls.ad), which:
#
#   * maps a fresh physical frame P at a HIGH user vaddr V (V != P, well
#     above any identity-mapped RAM), pre-poisoned with 0xAA,
#   * drives the CONVERTED _u_sysinfo(V, ...) handler,
#   * reads totalram + mem_unit DIRECTLY back from the PHYSICAL frame P
#     and asserts they match the live kernel accounting.
#
# A handler still raw-deref'ing V would write to unmapped memory and leave
# P poisoned; a poison-free, correct-field P is the proof the conversion
# translates. This is the same decoupling proof as the native syscall test,
# applied to the linux_abi/ sysinfo/getdents64/statx/rusage/times batch.
#
# The test is ALWAYS-ON at boot (no /etc marker), so this script just boots
# the default kernel and greps for the PASS marker. Needs NO block device.
#
# Boot path: a raw 64-bit Hamnix ELF will NOT boot under `qemu -kernel` on
# this host; the _kernel_iso.sh PATH shim (sourced by _build_lock.sh) wraps
# the ELFCLASS64 kernel in a BIOS GRUB ISO transparently.
#
# Pass marker:  [uaccess-lxabi] PASS
# Fail marker:  [uaccess-lxabi] FAIL / SKIP
#
# A QEMU timeout (rc=124) is EXPECTED/normal — the PASS line is the pass
# condition, not the process exit code.

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

export HAMNIX_BUILD_LOCK_TIMEOUT="${HAMNIX_BUILD_LOCK_TIMEOUT:-900}"

ELF=build/hamnix-kernel.elf

echo "[test_uaccess_linux_abi] (1/3) Build userland (init)"
bash scripts/build_user.sh >/dev/null

echo "[test_uaccess_linux_abi] (2/3) Build kernel image"
INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

LOG=$(mktemp)
trap 'rm -f "$LOG"' EXIT

echo "[test_uaccess_linux_abi] (3/3) Boot QEMU (no disk needed)"
set +e
timeout 180s qemu-system-x86_64 \
    -kernel "$ELF" \
    -smp 1 \
    -nographic -no-reboot -m 256M -monitor none -serial stdio \
    > "$LOG" 2>&1 < /dev/null
rc=$?
set -e

echo "[test_uaccess_linux_abi] --- captured (uaccess-lxabi lines) ---"
grep -E '\[uaccess-lxabi\]' "$LOG" || true
echo "[test_uaccess_linux_abi] --- end ---"

fail=0

if [ "$rc" -ne 0 ] && [ "$rc" -ne 124 ]; then
    echo "[test_uaccess_linux_abi] FAIL: qemu exited rc=$rc" >&2
    fail=1
fi

if grep -qF "[uaccess-lxabi] FAIL" "$LOG"; then
    echo "[test_uaccess_linux_abi] FAIL: handler did not translate (raw deref?)" >&2
    fail=1
fi
if grep -qF "[uaccess-lxabi] SKIP" "$LOG"; then
    echo "[test_uaccess_linux_abi] FAIL: self-test was skipped (alloc/map failed)" >&2
    fail=1
fi
if ! grep -qF "[uaccess-lxabi] PASS" "$LOG"; then
    echo "[test_uaccess_linux_abi] FAIL: PASS marker not found" >&2
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_uaccess_linux_abi] FAIL"
    exit 1
fi

echo "[test_uaccess_linux_abi] PASS — converted _u_sysinfo copies its struct out via copy_to_user through a vaddr != phys mapping"
