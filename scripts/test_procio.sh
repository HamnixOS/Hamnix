#!/usr/bin/env bash
# scripts/test_procio.sh — /proc/<pid>/io check.
#
# Proves the Linux-ABI /proc/<pid>/io node is REAL: rchar/wchar/syscr/syscw
# are per-task counters charged at the read()/write() syscall boundary
# (kernel/sched/core.ad, charged from linux_abi/u_syscalls.ad), read_bytes/
# write_bytes derive from the per-task 512-byte block-I/O counters
# (inblock/oublock * 512), and cancelled_write_bytes is 0. emit_proc_io
# (devproc.ad) renders the seven Linux-shape lines. The in-kernel
# procio_selftest() (gated on the cpio marker /etc/procio-test) stamps the
# boot slot's rchar/wchar/syscr/syscw (+ inblock/oublock) with known
# sentinels, renders emit_proc_io for the boot slot, parses the seven lines,
# and asserts rchar=1000 wchar=2000 syscr=11 syscw=22 read_bytes=1024
# write_bytes=1536. The selftest does all the work and needs NO extra QEMU disk.
#
# Boot path: a raw 64-bit Hamnix ELF will NOT boot under `qemu -kernel` on
# this host; the _kernel_iso.sh PATH shim (sourced by _build_lock.sh)
# transparently wraps the ELFCLASS64 kernel in a BIOS GRUB ISO, so the
# `-kernel "$ELF"` invocation below boots through the ISO shim.
#
# Pass marker:  [test_procio] PASS   (kernel prints [PROCIO] PASS)
# Fail marker:  [test_procio] FAIL

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

export HAMNIX_BUILD_LOCK_TIMEOUT="${HAMNIX_BUILD_LOCK_TIMEOUT:-900}"

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf

LOG=${HAMNIX_PROCIO_LOG:-$(mktemp)}
trap 'INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1 || true' EXIT

echo "[test_procio] (1/3) Build userland + plant /etc/procio-test + /init"
bash scripts/build_user.sh >/dev/null
INIT_ELF="$HAMSH_ELF" ENABLE_PROCIO_TEST=1 \
    python3 scripts/build_initramfs.py >/dev/null

echo "[test_procio] (2/3) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

echo "[test_procio] (3/3) Boot QEMU (no extra disk needed)"
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

echo "[test_procio] --- procio self-test output ---"
grep -a -E "\[PROCIO\]" "$LOG" || true
echo "[test_procio] --- end ---"

fail=0

if grep -a -F -q "[PROCIO] FAIL" "$LOG"; then
    echo "[test_procio] FAIL: kernel self-test reported an internal failure" >&2
    grep -a -F "[PROCIO] FAIL" "$LOG" >&2 || true
    fail=1
fi

if ! grep -a -F -q "[PROCIO] PASS" "$LOG"; then
    echo "[test_procio] MISS: self-test PASS banner (expected '[PROCIO] PASS')" >&2
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_procio] --- full log ---"
    cat "$LOG"
    echo "[test_procio] FAIL (qemu rc=$rc)"
    exit 1
fi

echo "[test_procio] PASS — /proc/<pid>/io real" \
     "(qemu rc=$rc)"
