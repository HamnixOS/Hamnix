#!/usr/bin/env bash
# scripts/test_close_range.sh -- close_range(2) + statx(2) for the Linux ABI.
#
# Modern glibc/coreutils reach for close_range(2) (nr 436) to drop a span of
# inherited fds in one trap, and call statx(2) (nr 332) instead of fstat for
# file metadata. Both handlers live in linux_abi/u_syscalls.ad (_u_close_range
# / _u_statx) and are wired into the central Linux-ABI dispatcher at their
# standard x86_64 syscall numbers. close_range routes each live fd through the
# same _u_close path a plain close(2) uses (so the per-fd teardown matches);
# statx fills the struct statx from the same per-backend metadata real fstat
# produces.
#
# This boots the kernel once with /etc/closerange-test planted
# (ENABLE_CLOSERANGE_TEST=1); init/main.ad's gate (boot:37.closerange) calls
# close_range_selftest() (linux_abi/u_syscalls.ad), which drives, in boot
# context, the SAME code the syscall entry points call:
#
#   * statx          : statx a known 8-byte file by path (AT_FDCWD); assert
#                      stx_mask carries STATX_BASIC_STATS, stx_size == 8, and
#                      the mode's S_IFMT bits are S_IFREG.
#   * tee + splice   : tee a payload pipe A -> pipe B (A stays intact), then
#                      splice B -> a file and read it back byte-for-byte.
#   * close_range    : dup a base fd four times, close_range the whole span,
#                      and assert every fd in it is closed (fds outside stay
#                      open); a second close_range over the empty span is a
#                      no-op success; an inverted range is EINVAL.
#
# Pass marker:  [test_close_range] PASS
# Fail marker:  [test_close_range] FAIL

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

export HAMNIX_BUILD_LOCK_TIMEOUT=900

ELF=build/hamnix-kernel.elf

echo "[test_close_range] (1/3) Build userland (init)"
bash scripts/build_user.sh >/dev/null

echo "[test_close_range] (2/3) Build kernel with /etc/closerange-test marker"
INIT_ELF=build/user/init.elf ENABLE_CLOSERANGE_TEST=1 \
    python3 scripts/build_initramfs.py >/dev/null
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1 || true' EXIT

echo "[test_close_range] (3/3) Boot QEMU and run the close_range/statx self-test"
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

echo "[test_close_range] --- close_range self-test output ---"
grep -aE "\[closerange\]" "$LOG" || true
echo "[test_close_range] --- end ---"

fail=0

if [ "$rc" -ne 0 ] && [ "$rc" -ne 124 ]; then
    echo "[test_close_range] FAIL: qemu exited rc=$rc" >&2
    fail=1
fi

# An explicit internal failure is fatal.
if grep -aqF "[closerange] FAIL" "$LOG"; then
    echo "[test_close_range] FAIL: kernel self-test reported a failure" >&2
    grep -aF "[closerange] FAIL" "$LOG" | head -5 || true
    fail=1
fi

# The kernel prints exactly "[closerange] PASS" on its own line (after an
# optional "[NNNNNN] " printk timestamp prefix) only when EVERY assertion
# held. Anchor to end-of-line so the per-leg "[closerange] ... OK" lines
# don't satisfy it.
if grep -aqE '(^|\] )\[closerange\] PASS$' "$LOG"; then
    echo "[test_close_range] PASS: overall self-test PASS banner"
else
    echo "[test_close_range] FAIL: overall self-test PASS banner missing" >&2
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_close_range] FAIL"
    exit 1
fi

echo "[test_close_range] PASS -- statx reports size/mode/type, tee+splice" \
     "moves bytes pipe->pipe->file, and close_range closes a span of dup'd" \
     "fds (idempotent re-run + EINVAL on an inverted range)"
