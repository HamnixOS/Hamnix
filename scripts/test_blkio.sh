#!/usr/bin/env bash
# scripts/test_blkio.sh — per-task block-I/O accounting verification.
#
# Proves the new per-task block-I/O counters (kernel/sched/core.ad inblock /
# oublock, charged from the block layer kernel/block/blk.ad at the I/O
# completion site via the current-task helpers) flow through _u_getrusage
# (linux_abi/u_syscalls.ad ru_inblock 0x58 / ru_oublock 0x60) and the read
# accessors. The in-kernel blkio_selftest() (gated on the cpio marker
# /etc/blkio-test) charges 8 block reads + 4 block writes via the same
# helpers the block layer drives, asserts the read accessors rose by exactly
# 8 / 4, then renders the rusage struct and asserts 0x58 / 0x60 match. The
# selftest does all the work and needs NO extra QEMU disk.
#
# Boot path: a raw 64-bit Hamnix ELF will NOT boot under `qemu -kernel` on
# this host; the _kernel_iso.sh PATH shim (sourced by _build_lock.sh)
# transparently wraps the ELFCLASS64 kernel in a BIOS GRUB ISO, so the
# `-kernel "$ELF"` invocation below boots through the ISO shim.
#
# Pass marker:  [test_blkio] PASS   (kernel prints [BLKIO] PASS)
# Fail marker:  [test_blkio] FAIL

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

export HAMNIX_BUILD_LOCK_TIMEOUT="${HAMNIX_BUILD_LOCK_TIMEOUT:-900}"

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf

LOG=${HAMNIX_BLKIO_LOG:-$(mktemp)}
trap 'INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1 || true' EXIT

echo "[test_blkio] (1/3) Build userland + plant /etc/blkio-test + /init"
bash scripts/build_user.sh >/dev/null
INIT_ELF="$HAMSH_ELF" ENABLE_BLKIO_TEST=1 \
    python3 scripts/build_initramfs.py >/dev/null

echo "[test_blkio] (2/3) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

echo "[test_blkio] (3/3) Boot QEMU (no extra disk needed)"
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

echo "[test_blkio] --- blkio self-test output ---"
grep -a -E "\[BLKIO\]" "$LOG" || true
echo "[test_blkio] --- end ---"

fail=0

if grep -a -F -q "[BLKIO] FAIL" "$LOG"; then
    echo "[test_blkio] FAIL: kernel self-test reported an internal failure" >&2
    grep -a -F "[BLKIO] FAIL" "$LOG" >&2 || true
    fail=1
fi

if ! grep -a -F -q "[BLKIO] PASS" "$LOG"; then
    echo "[test_blkio] MISS: self-test PASS banner (expected '[BLKIO] PASS')" >&2
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_blkio] --- full log ---"
    cat "$LOG"
    echo "[test_blkio] FAIL (qemu rc=$rc)"
    exit 1
fi

echo "[test_blkio] PASS — getrusage reports real per-task block I/O" \
     "(qemu rc=$rc)"
