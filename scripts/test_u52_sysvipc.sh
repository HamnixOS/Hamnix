#!/usr/bin/env bash
# scripts/test_u52_sysvipc.sh -- #U52, System V IPC (semaphores, message
# queues, shared memory) for the Linux ABI.
#
# Real Linux daemons (PostgreSQL, Apache prefork, ...) need SysV IPC. The
# implementation lives in linux_abi/u_sysvipc.ad and is wired into the
# central Linux-ABI dispatcher (linux_abi/u_syscalls.ad) at the standard
# x86_64 syscall numbers: shmget=29, shmat=30, shmctl=31, semget=64,
# semop=65, semctl=66, shmdt=67, msgget=68, msgsnd=69, msgrcv=70,
# msgctl=71.
#
# This test boots the kernel once with /etc/sysvipc-test planted
# (ENABLE_SYSVIPC_TEST=1); init/main.ad's sysvipc gate calls
# sysvipc_selftest() (linux_abi/u_sysvipc.ad), which exercises every
# primitive directly in boot context (driving the same code the syscall
# entry points call):
#
#   * SEMAPHORES: semget -> SETVAL/GETVAL; a decrement-below-zero op
#     returns -EAGAIN (NOWAIT), a raise unblocks it, then the decrement
#     succeeds; SETALL/GETALL round-trip; IPC_STAT; IPC_RMID then a use
#     of the dead id returns -EIDRM.
#   * MESSAGE QUEUES: msgget -> three messages of distinct types; msgrcv
#     with msgtyp 0 (FIFO), >0 (first of type), <0 (lowest type <= |t|)
#     prove the ordering rules; a NOWAIT recv on an empty queue returns
#     -ENOMSG; IPC_STAT reports qnum/cbytes.
#   * SHARED MEMORY: shmget -> two independent attaches (shmat) of the
#     same segment land on the SAME physical frames (write via attach A
#     is read back via attach B -- genuine cross-attach coherence under
#     the vaddr==phys identity map); IPC_STAT reports segsz/nattch;
#     shmdt; IPC_RMID.
#
# Pass marker:  [test_u52_sysvipc] PASS
# Fail marker:  [test_u52_sysvipc] FAIL

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

export HAMNIX_BUILD_LOCK_TIMEOUT=900

ELF=build/hamnix-kernel.elf

echo "[test_u52_sysvipc] (1/3) Build userland (init)"
bash scripts/build_user.sh >/dev/null

echo "[test_u52_sysvipc] (2/3) Build kernel with /etc/sysvipc-test marker"
INIT_ELF=build/user/init.elf ENABLE_SYSVIPC_TEST=1 \
    python3 scripts/build_initramfs.py >/dev/null
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1 || true' EXIT

echo "[test_u52_sysvipc] (3/3) Boot QEMU and run the SysV IPC self-test"
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

echo "[test_u52_sysvipc] --- SysV IPC self-test output ---"
grep -aE "\[sysvipc\]" "$LOG" || true
echo "[test_u52_sysvipc] --- end ---"

fail=0

if [ "$rc" -ne 0 ] && [ "$rc" -ne 124 ]; then
    echo "[test_u52_sysvipc] FAIL: qemu exited rc=$rc" >&2
    fail=1
fi

# An explicit internal failure is fatal.
if grep -aqF "[sysvipc] FAIL" "$LOG"; then
    echo "[test_u52_sysvipc] FAIL: kernel self-test reported a failure" >&2
    grep -aF "[sysvipc] FAIL" "$LOG" | head -5 || true
    fail=1
fi

# The kernel prints exactly "[sysvipc] PASS" on its own line (after an
# optional "[NNNNNN] " printk timestamp prefix) only when EVERY assertion
# held. Anchor to end-of-line so the per-assertion "[sysvipc] PASS: ..."
# lines (which have a trailing ": ...") don't satisfy it.
if grep -aqE '(^|\] )\[sysvipc\] PASS$' "$LOG"; then
    echo "[test_u52_sysvipc] PASS: overall self-test PASS banner"
else
    echo "[test_u52_sysvipc] FAIL: overall self-test PASS banner missing" >&2
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_u52_sysvipc] FAIL"
    exit 1
fi

echo "[test_u52_sysvipc] PASS -- SysV semaphores block/wake correctly," \
     "message queues honor msgtyp ordering, and two attaches of a shared" \
     "segment see the same physical pages"
