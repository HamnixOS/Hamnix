#!/usr/bin/env bash
# scripts/test_iouring.sh -- Linux io_uring async-I/O interface for the
# Linux ABI.
#
# io_uring is Linux's modern submission/completion-ring async-I/O API.
# The implementation lives in linux_abi/u_iouring.ad and is wired into the
# central Linux-ABI dispatcher (linux_abi/u_syscalls.ad) at the standard
# x86_64 syscall numbers: io_uring_setup=425, io_uring_enter=426,
# io_uring_register=427.
#
# This test boots the kernel once with /etc/iouring-test planted
# (ENABLE_IOURING_TEST=1); init/main.ad's io_uring gate (boot:37.iouring)
# calls iouring_selftest() (linux_abi/u_iouring.ad), which exercises the
# full path directly in boot context (driving the same functions the
# syscall entry points call):
#
#   * io_uring_setup(8, params): allocate a ring fd + kernel SQ/CQ/SQE
#     regions; report sq_off/cq_off offsets + the ring base (params-address
#     fallback) + sq_entries rounded to a power of two.
#   * submit a NOP via the SQ ring, io_uring_enter, assert the CQE
#     (user_data echoed, res 0).
#   * WRITEV bytes to a tmpfs file via the ring, then READV them back
#     byte-exact via the ring (reusing the vfs_write/vfs_read backends),
#     and FSYNC via the ring.
#   * WRITE_FIXED then READ_FIXED through a REGISTERED fixed buffer
#     (selected by SQE buf_index), byte-exact.
#   * OPENAT(create) -> WRITE -> CLOSE -> OPENAT(read) -> READ byte-exact,
#     then STATX of the same path (size assertion), all via the ring.
#   * POLL_ADD synchronous one-shot readiness (POLLIN on a regular file).
#   * io_uring_register/UNREGISTER buffers round-trip.
#
# Pass marker:  [iouring] PASS
# Fail marker:  [iouring] FAIL

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

export HAMNIX_BUILD_LOCK_TIMEOUT=900

ELF=build/hamnix-kernel.elf

echo "[test_iouring] (1/3) Build userland (init)"
bash scripts/build_user.sh >/dev/null

echo "[test_iouring] (2/3) Build kernel with /etc/iouring-test marker"
INIT_ELF=build/user/init.elf ENABLE_IOURING_TEST=1 \
    python3 scripts/build_initramfs.py >/dev/null
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1 || true' EXIT

echo "[test_iouring] (3/3) Boot QEMU and run the io_uring self-test"
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

echo "[test_iouring] --- io_uring self-test output ---"
grep -aE "\[iouring\]" "$LOG" || true
echo "[test_iouring] --- end ---"

fail=0

if [ "$rc" -ne 0 ] && [ "$rc" -ne 124 ]; then
    echo "[test_iouring] FAIL: qemu exited rc=$rc" >&2
    fail=1
fi

# An explicit internal failure is fatal.
if grep -aqF "[iouring] FAIL" "$LOG"; then
    echo "[test_iouring] FAIL: kernel self-test reported a failure" >&2
    grep -aF "[iouring] FAIL" "$LOG" | head -5 || true
    fail=1
fi

# The kernel prints exactly "[iouring] PASS" on its own line (after an
# optional "[NNNNNN] " printk timestamp prefix) only when EVERY assertion
# held. Anchor to end-of-line so the per-assertion "[iouring] PASS: ..."
# lines (which have a trailing ": ...") don't satisfy it.
if grep -aqE '(^|\] )\[iouring\] PASS$' "$LOG"; then
    echo "[test_iouring] PASS: overall self-test PASS banner"
else
    echo "[test_iouring] FAIL: overall self-test PASS banner missing" >&2
    fail=1
fi

# Per-opcode assertions for the new FILE/IO opcodes. Each must print its
# own PASS line; a missing line means the opcode path did not complete.
for marker in \
    "WRITE_FIXED/READ_FIXED byte-exact via reg buf" \
    "OPENAT(create) -> WRITE -> CLOSE via the ring" \
    "OPENAT(read) -> READ byte-exact via the ring" \
    "STATX via the ring (size=7)" \
    "POLL_ADD one-shot readiness (POLLIN ready)"
do
    if grep -aqF "[iouring] PASS: $marker" "$LOG"; then
        echo "[test_iouring] PASS: $marker"
    else
        echo "[test_iouring] FAIL: missing opcode PASS line: $marker" >&2
        fail=1
    fi
done

if [ "$fail" -ne 0 ]; then
    echo "[test_iouring] FAIL"
    exit 1
fi

echo "[test_iouring] PASS -- io_uring setup/enter/register round-trip:" \
     "NOP completion, WRITEV+READV byte-exact, FSYNC, WRITE_FIXED/READ_FIXED" \
     "via a registered buffer, OPENAT->WRITE->CLOSE->OPENAT->READ->STATX," \
     "POLL_ADD readiness, and register/unregister buffers"
