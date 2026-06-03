#!/usr/bin/env bash
# scripts/test_pty.sh — #165 Linux-ABI PTY (pseudo-terminal) self-test.
#
# Proves the new /dev/ptmx + /dev/pts/N pseudo-terminal layer
# (linux_abi/u_pty.ad, wired into fs/vfs.ad + linux_abi/u_syscalls.ad)
# works end-to-end through the real in-kernel Linux-ABI dispatch entry
# (linux_u_syscall_dispatch) — the exact path tmux / sshd-spawned ptys
# take:
#
#   * openat("/dev/ptmx", O_RDWR)         -> master fd
#   * ioctl(master, TIOCGPTN, &n)         -> slave index N
#   * a LOCKED slave open fails -EIO (before TIOCSPTLCK unlock)
#   * ioctl(master, TIOCSPTLCK, &0)       -> unlock
#   * openat("/dev/pts/N", O_RDWR)        -> slave fd
#   * write(master,"hi\n") -> cooked read(slave) returns "hi\n"
#   * the ECHO of "hi\n" appears on read(master)
#   * write(slave,"OK\n")  -> read(master) returns "OK\r\n" (OPOST|ONLCR)
#   * raw mode (TCSETS clears ICANON|ECHO): a single byte passes through
#     with NO echo and NO line assembly
#   * closing both ends frees the pair
#
# Mechanism (pure boot self-test, no userland interaction):
#   1. scripts/build_initramfs.py honours ENABLE_PTY_TEST=1: it plants
#      /etc/pty-test (the gate marker).
#   2. init/main.ad at boot:37.pty detects the marker and runs
#      pty_selftest() (linux_abi/u_syscalls.ad), which prints a single
#      "[PTY] PASS" line or "[PTY] FAIL ...".
#   3. We boot the kernel and grep the serial log for "[PTY] PASS".
#
# Default boots ship NO /etc/pty-test, so the self-test is a no-op skip
# everywhere else.
#
# Pass marker:  [test_pty] PASS
# Fail marker:  [test_pty] FAIL

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf
BOOT_TIMEOUT="${PTY_BOOT_TIMEOUT:-120}"

echo "[test_pty] (1/3) Build userland (init)"
bash scripts/build_user.sh >/dev/null

echo "[test_pty] (2/3) Build kernel with /etc/pty-test marker"
INIT_ELF=build/user/init.elf ENABLE_PTY_TEST=1 \
    python3 scripts/build_initramfs.py >/dev/null
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1 || true' EXIT

echo "[test_pty] (3/3) Boot QEMU and run the PTY self-test"
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

echo "[test_pty] --- PTY self-test output ---"
grep -a -E "\[PTY\]|\[boot:37.pty\]" "$LOG" || true
echo "[test_pty] --- end ---"

fail=0

# rc=124 is the expected timeout kill (kernel halts without powering off
# qemu); rc=0 a clean shutdown. Anything else is a real QEMU failure.
if [ "$rc" -ne 0 ] && [ "$rc" -ne 124 ]; then
    echo "[test_pty] FAIL: qemu exited rc=$rc" >&2
    fail=1
fi

if grep -a -qF "[PTY] FAIL" "$LOG"; then
    echo "[test_pty] FAIL: kernel self-test reported an internal failure" >&2
    grep -a -F "[PTY] FAIL" "$LOG" >&2 || true
    fail=1
fi

if ! grep -a -qF "[PTY] PASS" "$LOG"; then
    echo "[test_pty] FAIL: '[PTY] PASS' not found in serial log." >&2
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_pty] FAIL"
    exit 1
fi

echo "[test_pty] PASS — ptmx/pts open+ioctl+cooked/raw read+write+echo+close work via real dispatch"
