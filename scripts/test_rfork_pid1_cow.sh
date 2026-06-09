#!/usr/bin/env bash
# scripts/test_rfork_pid1_cow.sh — regression for the PID-1 hamsh
# first-rfork COW fatal page fault.
#
# THE BUG
# -------
# When PID-1 hamsh did its FIRST rfork (the `ns {}` / `spawn detached`
# at etc/rc.boot.full:57/:61), the child task took a deterministic fatal
# #PF: vector 0x0e err=0x07 (Present=1, Write=1, User=1) inside hamsh's
# own loaded image — a USER-mode WRITE to a PRESENT but READ-ONLY page.
#
# ROOT CAUSE
# ----------
# The ELF32 branch of fs/elf.ad::elf_load_blob() left the W^X read-only-
# span globals (elf_last_app_ro_n / elf_last_interp_ro_n) UNTOUCHED.
# Those globals are populated ONLY by the ELF64 loader
# (_collect_app_ro_spans). So if any Linux-ABI ELF64 binary loaded before
# a native ELF32 binary, the ELF32 image inherited the ELF64's stale RO
# spans. elf_apply_last_user_mapping()'s W^X Stage-1b pass then flipped
# those stale user vaddrs READ-ONLY inside the ELF32 image's PML4. When a
# stale span overlapped the ELF32 image's region_alloc()'d base, a
# .data/.bss page was left present+RO+non-COW. The image's first rfork()
# COW-shared that page VERBATIM-RO (it looks like a genuine W^X code page
# to _cow_share_one_page), so the child's first write to it faulted
# fatally with no COW bit to resolve — exactly the reported #PF.
#
# THE FIX
# -------
# fs/elf.ad::elf_load_blob() ELF32 branch now resets
# elf_last_app_ro_n = 0 and elf_last_interp_ro_n = 0: a native ELF32
# image (one RWE PT_LOAD, no RO segment) is always installed fully
# writable regardless of what loaded before it.
#
# THE TEST
# --------
# Kernel self-test elf32_wx_span_reset_selftest() (gated on the
# /etc/rfork-cow-test marker, planted by build_initramfs.py when
# ENABLE_RFORK_COW_TEST=1) plants a bogus non-zero RO-span count (as if
# an ELF64 loaded first), loads the native ELF32 /init image, and asserts
# the loader reset the spans to 0. It prints [rfork-cow] PASS on success.
#
# Verdict: PASS iff "[rfork-cow] PASS" appears AND no "TRAP: vector"
# fatal-trap line appears. BEFORE the fix the self-test prints
# "[rfork-cow] FAIL" (the planted spans survive the load); AFTER it
# prints PASS.

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf

echo "[test_rfork_pid1_cow] (1/3) Build userland (init shim + hamsh)"
bash scripts/build_user.sh >/dev/null

echo "[test_rfork_pid1_cow] (2/3) Plant /etc/rfork-cow-test marker in cpio"
ENABLE_RFORK_COW_TEST=1 python3 scripts/build_initramfs.py >/dev/null

echo "[test_rfork_pid1_cow] (3/3) Rebuild kernel + boot (fast -kernel ISO shim)"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

LOG=$(mktemp /tmp/test-rfork-pid1-cow.XXXXXX.log)
# Restore the default (markerless) initramfs on exit so a later build
# isn't left with the test marker baked in.
trap 'rm -f "$LOG"; python3 scripts/build_initramfs.py >/dev/null 2>&1 || true' EXIT

set +e
timeout 90s qemu-system-x86_64 \
    -kernel "$ELF" -smp 1 -nographic -no-reboot -m 512M \
    -monitor none -serial stdio </dev/null > "$LOG" 2>&1
set -e

echo "[test_rfork_pid1_cow] --- relevant serial output ---"
grep -aE "rfork-cow|TRAP: vector|boot:37.rfcow" "$LOG" | head -20 || true
echo "[test_rfork_pid1_cow] --- end ---"

fail=0

if grep -aq "\[rfork-cow\] PASS" "$LOG"; then
    echo "[test_rfork_pid1_cow] OK: ELF32 load reset W^X RO spans (no verbatim-RO COW share)"
else
    echo "[test_rfork_pid1_cow] MISS: [rfork-cow] PASS absent — stale W^X RO spans survived ELF32 load"
    fail=1
fi

if grep -aqE "TRAP: vector" "$LOG"; then
    echo "[test_rfork_pid1_cow] FAIL: fatal TRAP present:"
    grep -aE "TRAP: vector" "$LOG" | head -4 | sed 's/^/    /'
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_rfork_pid1_cow] FAIL"
    exit 1
fi

echo "[test_rfork_pid1_cow] PASS"
