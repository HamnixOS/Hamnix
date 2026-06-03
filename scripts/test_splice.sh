#!/usr/bin/env bash
# scripts/test_splice.sh -- pipe zero-copy I/O family (splice/tee/vmsplice)
# for the Linux ABI.
#
# Real Linux software that shuttles bytes between pipes and files reaches
# for splice(2)/tee(2)/vmsplice(2) (glibc tee(1), log shippers, the
# busybox/coreutils fast paths). The implementation lives in
# linux_abi/u_syscalls.ad (_u_splice / _u_tee / _u_vmsplice) and is wired
# into the central Linux-ABI dispatcher at the standard x86_64 syscall
# numbers: splice=275, tee=276, vmsplice=278. The handlers reuse the same
# VFS read/write data-move primitives sendfile / copy_file_range bounce
# through plus the anonymous-pipe ring (fs/pipe.ad), so the byte stream
# stays identical.
#
# This test boots the kernel once with /etc/splice-test planted
# (ENABLE_SPLICE_TEST=1); init/main.ad's splice gate (boot:37.splice)
# calls splice_selftest() (linux_abi/u_syscalls.ad), which exercises every
# primitive directly in boot context (driving the same code the syscall
# entry points call):
#
#   * file -> pipe splice : byte-exact transfer into a pipe.
#   * pipe -> file splice : byte-exact transfer out of a pipe with an
#     off_out pointer that advances by the bytes moved.
#   * pipe -> pipe splice : byte-exact transfer that consumes the source.
#   * tee                 : duplicate A->B WITHOUT consuming A — both the
#     copy on B and the original on A are still readable.
#   * vmsplice            : gather a real (vaddr != phys) user buffer into
#     a pipe via copy_from_user, byte-exact.
#   * error paths         : EINVAL when neither side is a pipe; ESPIPE for
#     an offset pointer on the pipe side.
#
# Pass marker:  [test_splice] PASS
# Fail marker:  [test_splice] FAIL

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

export HAMNIX_BUILD_LOCK_TIMEOUT=900

ELF=build/hamnix-kernel.elf

echo "[test_splice] (1/3) Build userland (init)"
bash scripts/build_user.sh >/dev/null

echo "[test_splice] (2/3) Build kernel with /etc/splice-test marker"
INIT_ELF=build/user/init.elf ENABLE_SPLICE_TEST=1 \
    python3 scripts/build_initramfs.py >/dev/null
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1 || true' EXIT

echo "[test_splice] (3/3) Boot QEMU and run the splice/tee/vmsplice self-test"
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

echo "[test_splice] --- splice self-test output ---"
grep -aE "\[splice\]" "$LOG" || true
echo "[test_splice] --- end ---"

fail=0

if [ "$rc" -ne 0 ] && [ "$rc" -ne 124 ]; then
    echo "[test_splice] FAIL: qemu exited rc=$rc" >&2
    fail=1
fi

# An explicit internal failure is fatal.
if grep -aqF "[splice] FAIL" "$LOG"; then
    echo "[test_splice] FAIL: kernel self-test reported a failure" >&2
    grep -aF "[splice] FAIL" "$LOG" | head -5 || true
    fail=1
fi

# The kernel prints exactly "[splice] PASS" on its own line (after an
# optional "[NNNNNN] " printk timestamp prefix) only when EVERY assertion
# held. Anchor to end-of-line so the per-leg "[splice] ... OK" lines don't
# satisfy it.
if grep -aqE '(^|\] )\[splice\] PASS$' "$LOG"; then
    echo "[test_splice] PASS: overall self-test PASS banner"
else
    echo "[test_splice] FAIL: overall self-test PASS banner missing" >&2
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_splice] FAIL"
    exit 1
fi

echo "[test_splice] PASS -- splice moves bytes between pipe and file" \
     "(and pipe<->pipe), tee duplicates without consuming the input, and" \
     "vmsplice gathers user iovec memory into a pipe; EINVAL/ESPIPE" \
     "error paths hold"
