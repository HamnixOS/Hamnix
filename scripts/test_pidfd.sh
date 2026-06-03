#!/usr/bin/env bash
# scripts/test_pidfd.sh -- the Linux pidfd process-management family.
#
# Real Linux service managers (systemd, runit, modern spawn helpers) use
# the pidfd API to refer to a process by a stable, race-free file
# descriptor instead of a recyclable pid. The implementation lives in
# linux_abi/u_pidfd.ad and is wired into the central Linux-ABI dispatcher
# (linux_abi/u_syscalls.ad) at the canonical x86_64 syscall numbers:
# pidfd_send_signal=424, pidfd_open=434, waitid=247.
#
# This test boots the kernel once with /etc/pidfd-test planted
# (ENABLE_PIDFD_TEST=1); init/main.ad's pidfd gate (boot:37.pidfd) calls
# do_pidfd_selftest() (linux_abi/u_pidfd.ad), which exercises every
# primitive directly in boot context against a synthesised target task
# (driving the same code the syscall entry points call):
#
#   * pidfd_open(pid) on a live task -> a valid fd, NOT POLLIN-readable.
#   * pidfd_open with a bad flag -> EINVAL; pid=0 -> EINVAL;
#     a dead pid -> ESRCH.
#   * pidfd_send_signal(SIGTERM) latches the signal on the target's
#     sig_pending (reusing the kernel signal_post delivery path).
#   * pidfd_send_signal on a non-pidfd fd -> EBADF; a bad signal -> EINVAL;
#     a bad flag -> EINVAL.
#   * once the target exits, the pidfd becomes POLLIN-readable.
#   * pidfd_send_signal to the now-gone target -> ESRCH.
#
# Pass marker:  [pidfd] PASS
# Fail marker:  [pidfd] FAIL

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

export HAMNIX_BUILD_LOCK_TIMEOUT=900

ELF=build/hamnix-kernel.elf

echo "[test_pidfd] (1/3) Build userland (init)"
bash scripts/build_user.sh >/dev/null

echo "[test_pidfd] (2/3) Build kernel with /etc/pidfd-test marker"
INIT_ELF=build/user/init.elf ENABLE_PIDFD_TEST=1 \
    python3 scripts/build_initramfs.py >/dev/null
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1 || true' EXIT

echo "[test_pidfd] (3/3) Boot QEMU and run the pidfd self-test"
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

echo "[test_pidfd] --- pidfd self-test output ---"
grep -aE "\[pidfd\]" "$LOG" || true
echo "[test_pidfd] --- end ---"

fail=0

if [ "$rc" -ne 0 ] && [ "$rc" -ne 124 ]; then
    echo "[test_pidfd] FAIL: qemu exited rc=$rc" >&2
    fail=1
fi

# An explicit internal failure is fatal.
if grep -aqF "[pidfd] FAIL" "$LOG"; then
    echo "[test_pidfd] FAIL: kernel self-test reported a failure" >&2
    grep -aF "[pidfd] FAIL" "$LOG" | head -5 || true
    fail=1
fi

# The kernel prints exactly "[pidfd] PASS" on its own line (after an
# optional "[NNNNNN] " printk timestamp prefix) only when EVERY assertion
# held. Anchor to end-of-line so the per-assertion "[pidfd] PASS: ..."
# lines (which have a trailing ": ...") don't satisfy it.
if grep -aqE '(^|\] )\[pidfd\] PASS$' "$LOG"; then
    echo "[test_pidfd] PASS: overall self-test PASS banner"
else
    echo "[test_pidfd] FAIL: overall self-test PASS banner missing" >&2
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_pidfd] FAIL"
    exit 1
fi

echo "[test_pidfd] PASS -- pidfd_open/pidfd_send_signal/waitid(P_PIDFD)" \
     "round-trip: a pidfd refers to a process, reuses the signal_post" \
     "delivery path, becomes POLLIN-readable on exit, and enforces" \
     "EBADF/ESRCH/EINVAL correctly"
