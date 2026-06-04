#!/usr/bin/env bash
# scripts/test_procfd.sh — /proc/<pid>/fd check.
#
# Gap-report #3. Proves the Linux-ABI /proc/<pid>/fd node is REAL: the per-task
# open-descriptor table comes from the real fd store (task_fd_idx_at /
# task_fd_buf_at, kernel/sched/core.ad). emit_proc_fd (devproc.ad) renders one
# "<fd>\t<target>\n" line per OPEN descriptor, with path-less anon objects in
# Linux's anon-inode "kind:[id]" shape. The in-kernel procfd_selftest() (gated
# on the cpio marker /etc/procfd-test) renders emit_proc_fd for the boot slot,
# asserts the standard descriptors 0/1/2 are listed and that the target column
# reads "/dev/cons". The selftest does all the work and needs NO extra QEMU
# disk.
#
# Boot path: a raw 64-bit Hamnix ELF will NOT boot under `qemu -kernel` on this
# host; the _kernel_iso.sh PATH shim (sourced by _build_lock.sh) transparently
# wraps the ELFCLASS64 kernel in a BIOS GRUB ISO, so the `-kernel "$ELF"`
# invocation below boots through the ISO shim.
#
# Pass marker:  [test_procfd] PASS   (kernel prints [PROCFD] PASS)
# Fail marker:  [test_procfd] FAIL

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

export HAMNIX_BUILD_LOCK_TIMEOUT="${HAMNIX_BUILD_LOCK_TIMEOUT:-900}"

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf

LOG=${HAMNIX_PROCFD_LOG:-$(mktemp)}
trap 'INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1 || true' EXIT

echo "[test_procfd] (1/3) Build userland + plant /etc/procfd-test + /init"
bash scripts/build_user.sh >/dev/null
INIT_ELF="$HAMSH_ELF" ENABLE_PROCFD_TEST=1 \
    python3 scripts/build_initramfs.py >/dev/null

echo "[test_procfd] (2/3) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

echo "[test_procfd] (3/3) Boot QEMU (no extra disk needed)"
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

echo "[test_procfd] --- procfd self-test output ---"
grep -a -E "\[PROCFD\]" "$LOG" || true
echo "[test_procfd] --- end ---"

fail=0

if grep -a -F -q "[PROCFD] FAIL" "$LOG"; then
    echo "[test_procfd] FAIL: kernel self-test reported an internal failure" >&2
    grep -a -F "[PROCFD] FAIL" "$LOG" >&2 || true
    fail=1
fi

if ! grep -a -F -q "[PROCFD] PASS" "$LOG"; then
    echo "[test_procfd] MISS: self-test PASS banner (expected '[PROCFD] PASS')" >&2
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_procfd] --- full log ---"
    cat "$LOG"
    echo "[test_procfd] FAIL (qemu rc=$rc)"
    exit 1
fi

echo "[test_procfd] PASS — /proc/<pid>/fd real" \
     "(qemu rc=$rc)"
