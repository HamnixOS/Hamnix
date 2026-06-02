#!/usr/bin/env bash
# scripts/test_childacct.sh — /proc/<pid>/stat child-resource accounting check.
#
# Proves the Linux-ABI /proc/<pid>/stat field 11 (cminflt), field 13 (cmajflt),
# field 16 (cutime) and field 17 (cstime) are REAL: they carry the rolled-up
# CPU ticks and page-fault counts of a parent's reaped children (whole subtree,
# RUSAGE_CHILDREN), folded in at task_reap (kernel/sched/core.ad) and emitted by
# _emit_linux_stat. They used to render the literal 0. The in-kernel
# childacct_selftest() (gated on the cpio marker /etc/childacct-test) stamps the
# boot slot's four child accumulators (cutime/cstime/cminflt/cmajflt) with known
# sentinels, asserts the accessors read them back, renders _emit_linux_stat for
# the boot slot, parses fields 11/13/16/17, and asserts they equal 33/44/11/22.
# It also exercises times(2)'s tms_cutime/tms_cstime path. The selftest does all
# the work and needs NO extra QEMU disk.
#
# Boot path: a raw 64-bit Hamnix ELF will NOT boot under `qemu -kernel` on
# this host; the _kernel_iso.sh PATH shim (sourced by _build_lock.sh)
# transparently wraps the ELFCLASS64 kernel in a BIOS GRUB ISO, so the
# `-kernel "$ELF"` invocation below boots through the ISO shim.
#
# Pass marker:  [test_childacct] PASS   (kernel prints [CHILDACCT] PASS)
# Fail marker:  [test_childacct] FAIL

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

export HAMNIX_BUILD_LOCK_TIMEOUT="${HAMNIX_BUILD_LOCK_TIMEOUT:-900}"

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf

LOG=${HAMNIX_CHILDACCT_LOG:-$(mktemp)}
trap 'INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1 || true' EXIT

echo "[test_childacct] (1/3) Build userland + plant /etc/childacct-test + /init"
bash scripts/build_user.sh >/dev/null
INIT_ELF="$HAMSH_ELF" ENABLE_CHILDACCT_TEST=1 \
    python3 scripts/build_initramfs.py >/dev/null

echo "[test_childacct] (2/3) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

echo "[test_childacct] (3/3) Boot QEMU (no extra disk needed)"
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

echo "[test_childacct] --- childacct self-test output ---"
grep -a -E "\[CHILDACCT\]" "$LOG" || true
echo "[test_childacct] --- end ---"

fail=0

if grep -a -F -q "[CHILDACCT] FAIL" "$LOG"; then
    echo "[test_childacct] FAIL: kernel self-test reported an internal failure" >&2
    grep -a -F "[CHILDACCT] FAIL" "$LOG" >&2 || true
    fail=1
fi

if ! grep -a -F -q "[CHILDACCT] PASS" "$LOG"; then
    echo "[test_childacct] MISS: self-test PASS banner (expected '[CHILDACCT] PASS')" >&2
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_childacct] --- full log ---"
    cat "$LOG"
    echo "[test_childacct] FAIL (qemu rc=$rc)"
    exit 1
fi

echo "[test_childacct] PASS — /proc/<pid>/stat child-resource accounting" \
     "(fields 11/13/16/17) real (qemu rc=$rc)"
