#!/usr/bin/env bash
# scripts/test_pgrp.sh — /proc/<pid>/stat pgrp (field 5) check.
#
# Proves the Linux-ABI /proc/<pid>/stat field 5 (pgrp = job process-group
# id) is REAL: it is the task's per-task job_pgid from kernel/sched/core.ad
# (task_get_job_pgid), emitted by _emit_linux_stat. It used to render the
# literal 0. The in-kernel pgrp_selftest() (gated on the cpio marker
# /etc/pgrp-test) sets the boot slot's job_pgid to a known sentinel (4242),
# renders _emit_linux_stat for the boot slot, parses field 5 (unsigned), and
# asserts it equals 4242. The selftest does all the work and needs NO extra
# QEMU disk.
#
# Boot path: a raw 64-bit Hamnix ELF will NOT boot under `qemu -kernel` on
# this host; the _kernel_iso.sh PATH shim (sourced by _build_lock.sh)
# transparently wraps the ELFCLASS64 kernel in a BIOS GRUB ISO, so the
# `-kernel "$ELF"` invocation below boots through the ISO shim.
#
# Pass marker:  [test_pgrp] PASS   (kernel prints [PGRP] PASS)
# Fail marker:  [test_pgrp] FAIL

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

export HAMNIX_BUILD_LOCK_TIMEOUT="${HAMNIX_BUILD_LOCK_TIMEOUT:-900}"

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf

LOG=${HAMNIX_PGRP_LOG:-$(mktemp)}
trap 'INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1 || true' EXIT

echo "[test_pgrp] (1/3) Build userland + plant /etc/pgrp-test + /init"
bash scripts/build_user.sh >/dev/null
INIT_ELF="$HAMSH_ELF" ENABLE_PGRP_TEST=1 \
    python3 scripts/build_initramfs.py >/dev/null

echo "[test_pgrp] (2/3) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

echo "[test_pgrp] (3/3) Boot QEMU (no extra disk needed)"
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

echo "[test_pgrp] --- pgrp self-test output ---"
grep -a -E "\[PGRP\]" "$LOG" || true
echo "[test_pgrp] --- end ---"

fail=0

if grep -a -F -q "[PGRP] FAIL" "$LOG"; then
    echo "[test_pgrp] FAIL: kernel self-test reported an internal failure" >&2
    grep -a -F "[PGRP] FAIL" "$LOG" >&2 || true
    fail=1
fi

if ! grep -a -F -q "[PGRP] PASS" "$LOG"; then
    echo "[test_pgrp] MISS: self-test PASS banner (expected '[PGRP] PASS')" >&2
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_pgrp] --- full log ---"
    cat "$LOG"
    echo "[test_pgrp] FAIL (qemu rc=$rc)"
    exit 1
fi

echo "[test_pgrp] PASS — /proc/<pid>/stat pgrp (field 5) real" \
     "(qemu rc=$rc)"
