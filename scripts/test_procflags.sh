#!/usr/bin/env bash
# scripts/test_procflags.sh — /proc/<pid>/stat flags (field 9) check.
#
# Proves the Linux-ABI /proc/<pid>/stat field 9 (flags = the task's Linux PF_*
# kernel flags word) is REAL: it carries the PF_KTHREAD bit (0x00200000 =
# 2097152) derived from the task's per-task is_user from kernel/sched/core.ad
# (task_is_user_at), emitted by _emit_linux_stat. It used to render the
# literal 0. The in-kernel procflags_selftest() (gated on the cpio marker
# /etc/procflags-test) renders _emit_linux_stat for the boot slot, parses
# field 9 (unsigned), and asserts it equals the real PF_KTHREAD bit derived
# from the boot task's is_user (the boot/current task is a kernel thread, so
# 2097152). The selftest does all the work and needs NO extra QEMU disk.
#
# Boot path: a raw 64-bit Hamnix ELF will NOT boot under `qemu -kernel` on
# this host; the _kernel_iso.sh PATH shim (sourced by _build_lock.sh)
# transparently wraps the ELFCLASS64 kernel in a BIOS GRUB ISO, so the
# `-kernel "$ELF"` invocation below boots through the ISO shim.
#
# Pass marker:  [test_procflags] PASS   (kernel prints [PROCFLAGS] PASS)
# Fail marker:  [test_procflags] FAIL

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

export HAMNIX_BUILD_LOCK_TIMEOUT="${HAMNIX_BUILD_LOCK_TIMEOUT:-900}"

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf

LOG=${HAMNIX_PROCFLAGS_LOG:-$(mktemp)}
trap 'INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1 || true' EXIT

echo "[test_procflags] (1/3) Build userland + plant /etc/procflags-test + /init"
bash scripts/build_user.sh >/dev/null
INIT_ELF="$HAMSH_ELF" ENABLE_PROCFLAGS_TEST=1 \
    python3 scripts/build_initramfs.py >/dev/null

echo "[test_procflags] (2/3) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

echo "[test_procflags] (3/3) Boot QEMU (no extra disk needed)"
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

echo "[test_procflags] --- procflags self-test output ---"
grep -a -E "\[PROCFLAGS\]" "$LOG" || true
echo "[test_procflags] --- end ---"

fail=0

if grep -a -F -q "[PROCFLAGS] FAIL" "$LOG"; then
    echo "[test_procflags] FAIL: kernel self-test reported an internal failure" >&2
    grep -a -F "[PROCFLAGS] FAIL" "$LOG" >&2 || true
    fail=1
fi

if ! grep -a -F -q "[PROCFLAGS] PASS" "$LOG"; then
    echo "[test_procflags] MISS: self-test PASS banner (expected '[PROCFLAGS] PASS')" >&2
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_procflags] --- full log ---"
    cat "$LOG"
    echo "[test_procflags] FAIL (qemu rc=$rc)"
    exit 1
fi

echo "[test_procflags] PASS — /proc/<pid>/stat flags (field 9) real" \
     "(qemu rc=$rc)"
