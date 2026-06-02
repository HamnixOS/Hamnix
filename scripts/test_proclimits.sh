#!/usr/bin/env bash
# scripts/test_proclimits.sh — /proc/<pid>/limits check.
#
# Proves the Linux-ABI /proc/<pid>/limits node is REAL: the per-task resource
# limits come from the real rlimit store (rlimit_get_cur/rlimit_get_max,
# kernel/sched/core.ad), seeded at task creation to the Linux login defaults.
# emit_proc_limits (devproc.ad) renders the header row plus one line per
# RLIM_NLIMITS(16) resource, with the literal "unlimited" for RLIM_INFINITY
# values. The in-kernel proclimits_selftest() (gated on the cpio marker
# /etc/proclimits-test) renders emit_proc_limits for the boot slot, parses the
# "Max open files"/"Max stack size" rows, and asserts nofile_soft=1024
# nofile_hard=4096 stack_soft=8388608. The selftest does all the work and needs
# NO extra QEMU disk.
#
# Boot path: a raw 64-bit Hamnix ELF will NOT boot under `qemu -kernel` on
# this host; the _kernel_iso.sh PATH shim (sourced by _build_lock.sh)
# transparently wraps the ELFCLASS64 kernel in a BIOS GRUB ISO, so the
# `-kernel "$ELF"` invocation below boots through the ISO shim.
#
# Pass marker:  [test_proclimits] PASS   (kernel prints [PROCLIMITS] PASS)
# Fail marker:  [test_proclimits] FAIL

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

export HAMNIX_BUILD_LOCK_TIMEOUT="${HAMNIX_BUILD_LOCK_TIMEOUT:-900}"

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf

LOG=${HAMNIX_PROCLIMITS_LOG:-$(mktemp)}
trap 'INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1 || true' EXIT

echo "[test_proclimits] (1/3) Build userland + plant /etc/proclimits-test + /init"
bash scripts/build_user.sh >/dev/null
INIT_ELF="$HAMSH_ELF" ENABLE_PROCLIMITS_TEST=1 \
    python3 scripts/build_initramfs.py >/dev/null

echo "[test_proclimits] (2/3) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

echo "[test_proclimits] (3/3) Boot QEMU (no extra disk needed)"
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

echo "[test_proclimits] --- proclimits self-test output ---"
grep -a -E "\[PROCLIMITS\]" "$LOG" || true
echo "[test_proclimits] --- end ---"

fail=0

if grep -a -F -q "[PROCLIMITS] FAIL" "$LOG"; then
    echo "[test_proclimits] FAIL: kernel self-test reported an internal failure" >&2
    grep -a -F "[PROCLIMITS] FAIL" "$LOG" >&2 || true
    fail=1
fi

if ! grep -a -F -q "[PROCLIMITS] PASS" "$LOG"; then
    echo "[test_proclimits] MISS: self-test PASS banner (expected '[PROCLIMITS] PASS')" >&2
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_proclimits] --- full log ---"
    cat "$LOG"
    echo "[test_proclimits] FAIL (qemu rc=$rc)"
    exit 1
fi

echo "[test_proclimits] PASS — /proc/<pid>/limits real" \
     "(qemu rc=$rc)"
