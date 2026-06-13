#!/usr/bin/env bash
# scripts/test_seccomp_native.sh — F10-8 / #457 NATIVE seccomp-lite
# per-task syscall-filter verification.
#
# Proves the NATIVE (Layer-1) seccomp surface: each task carries a
# 256-bit allow-list bitmap (kernel/sched/core.ad seccomp_native_filter)
# consulted by arch/x86/kernel/syscall.ad::do_syscall BEFORE the native
# dispatch ladder. A blocked nr is bounced with -EPERM in %rax. The
# in-kernel seccomp_native_selftest() (gated on cpio marker
# /etc/seccomp-native-test) drives the REAL filter store + the
# do_syscall-entry probe over a spare task slot, asserting:
#   * disarmed probe lets every nr through;
#   * armed allow-only-SYS_GETPID(4) bitmap blocks nr=0/8 and nr>=256;
#   * the armed bit is IRREVOCABLE — disarm via the accessor is a no-op.
#
# The selftest does all the work and needs NO extra QEMU disk.
#
# Boot path: a raw 64-bit Hamnix ELF will NOT boot under `qemu -kernel`
# on this host; _kernel_iso.sh (sourced via _build_lock.sh) wraps the
# ELFCLASS64 kernel in a BIOS GRUB ISO transparently.
#
# Pass marker:  [test_seccomp_native] PASS (kernel prints [SECCOMPN] PASS)
# Fail marker:  [test_seccomp_native] FAIL

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

export HAMNIX_BUILD_LOCK_TIMEOUT="${HAMNIX_BUILD_LOCK_TIMEOUT:-900}"

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf

LOG=${HAMNIX_SECCOMP_NATIVE_LOG:-$(mktemp)}
trap 'INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1 || true' EXIT

echo "[test_seccomp_native] (1/3) Build userland + plant /etc/seccomp-native-test + /init"
bash scripts/build_user.sh >/dev/null
INIT_ELF="$HAMSH_ELF" ENABLE_SECCOMP_NATIVE_TEST=1 \
    python3 scripts/build_initramfs.py >/dev/null

echo "[test_seccomp_native] (2/3) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

echo "[test_seccomp_native] (3/3) Boot QEMU (no extra disk needed)"
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

echo "[test_seccomp_native] --- seccomp-native self-test output ---"
grep -a -E "\[SECCOMPN\]" "$LOG" || true
echo "[test_seccomp_native] --- end ---"

fail=0

if grep -a -F -q "[SECCOMPN] FAIL" "$LOG"; then
    echo "[test_seccomp_native] FAIL: kernel self-test reported an internal failure" >&2
    grep -a -F "[SECCOMPN] FAIL" "$LOG" >&2 || true
    fail=1
fi

if ! grep -a -F -q "[SECCOMPN] PASS" "$LOG"; then
    echo "[test_seccomp_native] MISS: self-test PASS banner (expected '[SECCOMPN] PASS')" >&2
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_seccomp_native] --- full log ---"
    cat "$LOG"
    echo "[test_seccomp_native] FAIL (qemu rc=$rc)"
    exit 1
fi

echo "[test_seccomp_native] PASS — native per-task syscall filter + irrevocable arming verified" \
     "(qemu rc=$rc)"
