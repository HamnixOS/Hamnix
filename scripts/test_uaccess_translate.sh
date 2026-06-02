#!/usr/bin/env bash
# scripts/test_uaccess_translate.sh — Stage A proof for the real uaccess
# translation layer (mm/uaccess.ad).
#
# WHAT IT PROVES
#
# The kernel used to dereference user pointers DIRECTLY, relying on the
# invariant `user vaddr == phys` (everything identity-mapped). That made
# ET_DYN / mmap-base ASLR impossible. mm/uaccess.ad replaces the cheat
# with copy_to_user / copy_from_user / get_user / put_user /
# strncpy_from_user / clear_user helpers that WALK the current task's
# page tables to translate a user vaddr -> physical frame before touching
# it, faulting safely (-EFAULT residual) instead of #PF-panicking.
#
# The boot-time uaccess_smoke_test() (init/main.ad, run right after
# page_alloc_smoke_test) installs a fresh physical page at a user vaddr
# DELIBERATELY OFFSET from its physical frame — a genuine non-identity
# mapping, vaddr != phys — and proves:
#   1. copy_to_user(V, ...) lands at the PHYSICAL frame (not at V),
#   2. copy_from_user(..., V) round-trips through the same translation,
#   3. an UNMAPPED user address returns the full residual (EFAULT, no panic),
#   4. a READ-ONLY user page is readable but rejects copy_to_user.
#
# uaccess_syscall_test() (arch/x86/kernel/syscall.ad, run immediately
# after) goes one level UP: it maps a non-identity user page and drives
# the CONVERTED SYS_GETCWD handler through do_syscall(), proving the
# SYSCALL LAYER (not just the copy_to_user primitive) translates rather
# than raw-derefs — the cwd bytes land at the physical frame, the poison
# we pre-write is gone, and the return value is the string length + NUL.
#
# This fixture boots the kernel ONCE and asserts all PASS markers plus
# the absence of any FAIL marker. A PASS therefore demonstrates that
# user vaddr no longer has to equal phys — the decoupling is real both
# at the primitive layer AND through a real converted syscall.
#
# NOTE: a trailing QEMU rc=124 AFTER the markers have printed is benign
# (the kernel halts without powering off qemu); the grep checks below are
# authoritative.

. "$(dirname "$0")/_build_lock.sh"
. "$(dirname "$0")/_qemu_drive.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf

echo "[test_uaccess] (1/2) Build initramfs + kernel"
bash scripts/build_user.sh >/dev/null
INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF"

echo "[test_uaccess] (2/2) Boot and capture uaccess smoke markers"
LOG=$(mktemp)
trap 'rm -f "$LOG"' EXIT
set +e
qemu_drive "$LOG" "$ELF" "[uaccess-sc] done" 70 -- "exit" 1
set -e

echo "[test_uaccess] --- uaccess smoke + syscall lines ---"
grep -a "uaccess-smoke\|uaccess-sc" "$LOG" || true

fail=0

# No FAIL marker anywhere (primitive layer OR syscall layer).
if grep -a -q "\[uaccess-smoke\] FAIL" "$LOG"; then
    echo "[test_uaccess] MISS: a uaccess-smoke FAIL marker is present"
    fail=1
fi
if grep -a -q "\[uaccess-sc\] FAIL" "$LOG"; then
    echo "[test_uaccess] MISS: a uaccess-sc FAIL marker is present"
    fail=1
fi

# All PASS markers present — four primitive-layer + the syscall-layer one.
need=(
    "copy_to_user reached the physical frame"
    "copy_from_user round-tripped through V"
    "unmapped address -> EFAULT (no panic)"
    "RO page readable, write -> EFAULT"
    "SYS_GETCWD copied to the physical frame"
    "strncpy_from_user copied a path via V != phys"
)
for m in "${need[@]}"; do
    if grep -a -q -F "$m" "$LOG"; then
        echo "[test_uaccess] OK: '$m'"
    else
        echo "[test_uaccess] MISS: '$m' not found"
        fail=1
    fi
done

if [ "$fail" -ne 0 ]; then
    echo "[test_uaccess] DIAG tail:"
    tail -40 "$LOG" || true
    echo "[test_uaccess] FAIL"
    exit 1
fi

echo "[test_uaccess] PASS — copy_to/from_user translate a user vaddr != phys" \
     "through the current task's page tables (with safe -EFAULT on fault)," \
     "and the converted SYS_GETCWD handler does the same end-to-end"
