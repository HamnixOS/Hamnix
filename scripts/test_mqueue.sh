#!/usr/bin/env bash
# scripts/test_mqueue.sh -- POSIX message queues (mq_*) for the Linux ABI.
#
# Real Linux realtime software reaches for the POSIX.1b message-queue API
# (mq_open/mq_send/mq_receive/mq_getattr/mq_unlink). The implementation
# lives in linux_abi/u_posixmq.ad and is wired into the central Linux-ABI
# dispatcher (linux_abi/u_syscalls.ad) at the standard x86_64 syscall
# numbers: mq_open=240, mq_unlink=241, mq_timedsend=242,
# mq_timedreceive=243, mq_getsetattr=245.
#
# This test boots the kernel once with /etc/mqueue-test planted
# (ENABLE_MQUEUE_TEST=1); init/main.ad's mqueue gate (boot:37.mq) calls
# posixmq_selftest() (linux_abi/u_posixmq.ad), which exercises every
# primitive directly in boot context (driving the same code the syscall
# entry points call):
#
#   * mq_open create (O_CREAT) with mq_attr maxmsg=4/msgsize=16; O_EXCL on
#     the existing name -> EEXIST.
#   * mq_send + mq_receive round-trips a message's length, data and prio.
#   * PRIORITY-ordered delivery: a high-prio message sent AFTER a low-prio
#     one is received FIRST; equal priority is FIFO.
#   * EMSGSIZE on an oversize send (> mq_msgsize).
#   * EAGAIN on O_NONBLOCK empty-receive AND O_NONBLOCK full-send.
#   * mq_getattr reports maxmsg/msgsize/curmsgs.
#   * mq_unlink, then a non-CREAT open of the gone name -> ENOENT; a
#     double-close -> EBADF.
#
# Pass marker:  [test_mqueue] PASS
# Fail marker:  [test_mqueue] FAIL

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

export HAMNIX_BUILD_LOCK_TIMEOUT=900

ELF=build/hamnix-kernel.elf

echo "[test_mqueue] (1/3) Build userland (init)"
bash scripts/build_user.sh >/dev/null

echo "[test_mqueue] (2/3) Build kernel with /etc/mqueue-test marker"
INIT_ELF=build/user/init.elf ENABLE_MQUEUE_TEST=1 \
    python3 scripts/build_initramfs.py >/dev/null
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1 || true' EXIT

echo "[test_mqueue] (3/3) Boot QEMU and run the POSIX mqueue self-test"
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

echo "[test_mqueue] --- POSIX mqueue self-test output ---"
grep -aE "\[mqueue\]" "$LOG" || true
echo "[test_mqueue] --- end ---"

fail=0

if [ "$rc" -ne 0 ] && [ "$rc" -ne 124 ]; then
    echo "[test_mqueue] FAIL: qemu exited rc=$rc" >&2
    fail=1
fi

# An explicit internal failure is fatal.
if grep -aqF "[mqueue] FAIL" "$LOG"; then
    echo "[test_mqueue] FAIL: kernel self-test reported a failure" >&2
    grep -aF "[mqueue] FAIL" "$LOG" | head -5 || true
    fail=1
fi

# The kernel prints exactly "[mqueue] PASS" on its own line (after an
# optional "[NNNNNN] " printk timestamp prefix) only when EVERY assertion
# held. Anchor to end-of-line so the per-assertion "[mqueue] PASS: ..."
# lines (which have a trailing ": ...") don't satisfy it.
if grep -aqE '(^|\] )\[mqueue\] PASS$' "$LOG"; then
    echo "[test_mqueue] PASS: overall self-test PASS banner"
else
    echo "[test_mqueue] FAIL: overall self-test PASS banner missing" >&2
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_mqueue] FAIL"
    exit 1
fi

echo "[test_mqueue] PASS -- POSIX message queues round-trip, honor" \
     "priority-ordered delivery (high prio first, FIFO among equals), and" \
     "enforce EMSGSIZE/EAGAIN/ENOENT/EBADF correctly"
