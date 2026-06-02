#!/usr/bin/env bash
# scripts/test_prionice.sh — /proc/<pid>/stat priority+nice (fields 18/19) check.
#
# Proves the Linux-ABI /proc/<pid>/stat field 18 (priority) and field 19
# (nice) are REAL: field 19 is the task's POSIX nice value (-20..+19,
# SIGNED) from kernel/sched/core.ad (sched_get_nice), and field 18 is the
# Linux kernel priority for a normal task = 20 + nice (range 0..39), both
# emitted by _emit_linux_stat. They used to render the literal 0. The
# in-kernel prionice_selftest() (gated on the cpio marker
# /etc/prionice-test) sets the boot slot's nice to a known negative value,
# asserts the accessor reads it back, renders _emit_linux_stat for the boot
# slot, parses field 18 (unsigned) and field 19 (signed), and asserts they
# equal 15 / -5. The selftest does all the work and needs NO extra QEMU disk.
#
# Boot path: a raw 64-bit Hamnix ELF will NOT boot under `qemu -kernel` on
# this host; the _kernel_iso.sh PATH shim (sourced by _build_lock.sh)
# transparently wraps the ELFCLASS64 kernel in a BIOS GRUB ISO, so the
# `-kernel "$ELF"` invocation below boots through the ISO shim.
#
# Pass marker:  [test_prionice] PASS   (kernel prints [PRIONICE] PASS)
# Fail marker:  [test_prionice] FAIL

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

export HAMNIX_BUILD_LOCK_TIMEOUT="${HAMNIX_BUILD_LOCK_TIMEOUT:-900}"

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf

LOG=${HAMNIX_PRIONICE_LOG:-$(mktemp)}
trap 'INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1 || true' EXIT

echo "[test_prionice] (1/3) Build userland + plant /etc/prionice-test + /init"
bash scripts/build_user.sh >/dev/null
INIT_ELF="$HAMSH_ELF" ENABLE_PRIONICE_TEST=1 \
    python3 scripts/build_initramfs.py >/dev/null

echo "[test_prionice] (2/3) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

echo "[test_prionice] (3/3) Boot QEMU (no extra disk needed)"
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

echo "[test_prionice] --- prionice self-test output ---"
grep -a -E "\[PRIONICE\]" "$LOG" || true
echo "[test_prionice] --- end ---"

fail=0

if grep -a -F -q "[PRIONICE] FAIL" "$LOG"; then
    echo "[test_prionice] FAIL: kernel self-test reported an internal failure" >&2
    grep -a -F "[PRIONICE] FAIL" "$LOG" >&2 || true
    fail=1
fi

if ! grep -a -F -q "[PRIONICE] PASS" "$LOG"; then
    echo "[test_prionice] MISS: self-test PASS banner (expected '[PRIONICE] PASS')" >&2
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_prionice] --- full log ---"
    cat "$LOG"
    echo "[test_prionice] FAIL (qemu rc=$rc)"
    exit 1
fi

echo "[test_prionice] PASS — /proc/<pid>/stat priority+nice (fields 18/19) real" \
     "(qemu rc=$rc)"
