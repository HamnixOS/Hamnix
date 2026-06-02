#!/usr/bin/env bash
# scripts/test_uabi_fills.sh — linux-abi U-ABI fills self-test.
#
# Proves the newly-filled Linux-ABI syscall handlers in
# linux_abi/u_syscalls.ad work end-to-end through the real in-kernel
# dispatch entry (linux_u_syscall_dispatch) — the exact path a
# Debian/glibc binary takes:
#
#   * arch_prctl(ARCH_SET_FS) / arch_prctl(ARCH_GET_FS) roundtrip,
#   * readlink("/proc/self/exe", ...) returns a non-empty target,
#   * uname() fills the utsname struct,
#   * newfstatat(AT_FDCWD, "/etc/uabi-fills-test", ...) stats the file,
#   * pwrite64(fd, buf, n, off) writes at the offset WITHOUT moving the
#     fd position, verified by reading the bytes back via pread64.
#
# Mechanism (pure boot self-test, no userland interaction):
#   1. scripts/build_initramfs.py honours ENABLE_UABI_FILLS_TEST=1: it
#      plants /etc/uabi-fills-test (the gate marker, also the file
#      newfstatat stats).
#   2. init/main.ad at boot:37.uaf detects the marker and runs
#      uabi_fills_selftest() (linux_abi/u_syscalls.ad), which prints a
#      single "[UABI_FILLS] PASS" line or "[UABI_FILLS] FAIL ...".
#   3. We boot the kernel (the _build_lock.sh qemu shim wraps the 64-bit
#      ELF in a BIOS GRUB ISO automatically — a raw `-kernel` of the
#      higher-half ELF does not boot on this host) and grep the serial
#      log for "[UABI_FILLS] PASS".
#
# Default boots ship NO /etc/uabi-fills-test, so the self-test is a
# no-op skip everywhere else.
#
# Pass marker:  [test_uabi_fills] PASS
# Fail marker:  [test_uabi_fills] FAIL

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf
BOOT_TIMEOUT="${UABI_FILLS_BOOT_TIMEOUT:-120}"

echo "[test_uabi_fills] (1/3) Build userland (init)"
bash scripts/build_user.sh >/dev/null

echo "[test_uabi_fills] (2/3) Build kernel with /etc/uabi-fills-test marker"
INIT_ELF=build/user/init.elf ENABLE_UABI_FILLS_TEST=1 \
    python3 scripts/build_initramfs.py >/dev/null
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1 || true' EXIT

echo "[test_uabi_fills] (3/3) Boot QEMU and run the U-ABI fills self-test"
set +e
timeout "${BOOT_TIMEOUT}s" qemu-system-x86_64 \
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

echo "[test_uabi_fills] --- U-ABI fills self-test output ---"
grep -a -E "\[UABI_FILLS\]|\[boot:37.uaf\]" "$LOG" || true
echo "[test_uabi_fills] --- end ---"

fail=0

# rc=124 is the expected timeout kill (kernel halts without powering off
# qemu); rc=0 a clean shutdown. Anything else is a real QEMU failure.
if [ "$rc" -ne 0 ] && [ "$rc" -ne 124 ]; then
    echo "[test_uabi_fills] FAIL: qemu exited rc=$rc" >&2
    fail=1
fi

# An explicit internal failure is fatal.
if grep -a -qF "[UABI_FILLS] FAIL" "$LOG"; then
    echo "[test_uabi_fills] FAIL: kernel self-test reported an internal failure" >&2
    grep -a -F "[UABI_FILLS] FAIL" "$LOG" >&2 || true
    fail=1
fi

if ! grep -a -qF "[UABI_FILLS] PASS" "$LOG"; then
    echo "[test_uabi_fills] FAIL: '[UABI_FILLS] PASS' not found in serial log." >&2
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_uabi_fills] FAIL"
    exit 1
fi

echo "[test_uabi_fills] PASS — readlink/arch_prctl/uname/newfstatat/pwrite64 plus preadv/pwritev, faccessat2, fchmod/fchown, umask, getcpu, sched_get/setaffinity, membarrier, mkdirat/unlinkat, clock_nanosleep via real dispatch"
