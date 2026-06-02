#!/usr/bin/env bash
# scripts/test_nscap.sh — #174, per-namespace CPU + memory resource caps.
#
# Hamnix binds resource caps to the Plan-9 NAMESPACE object (the Pgrp),
# NOT to a Linux cgroup or a POSIX rlimit. This test boots the kernel once
# with /etc/nscap-test planted (ENABLE_NSCAP_TEST=1); init/main.ad at
# boot:37.nsc calls nscap_selftest() (mm/nscap_test.ad), which:
#
#   * builds TWO real user tasks, each in its OWN fresh namespace,
#   * caps one namespace's memory at 16 pages and leaves the other
#     uncapped,
#   * drives the real demand-fault populator (vma_demand_fault) for 32
#     pages in EACH namespace, and
#   * asserts the capped namespace is DENIED past its cap (exactly 16
#     pages permitted) while the UNCAPPED namespace faults ALL 32 — the
#     unforgeable proof that the cap, not a global shortage, did the
#     denial.
#
# It also installs a 25% CPU cap and asserts the scheduler's
# vruntime-inflation factor is 4 (100/25), the throttle the CFS-lite
# picker applies in preempt_tick.
#
# Boot path: a raw 64-bit Hamnix ELF will NOT boot under `qemu -kernel`
# on this host; the _kernel_iso.sh PATH shim (sourced by _build_lock.sh)
# transparently wraps the ELFCLASS64 kernel in a BIOS GRUB ISO, so the
# `-kernel "$ELF"` invocation below boots through the ISO shim.
#
# Pass marker:  [test_nscap] PASS
# Fail marker:  [test_nscap] FAIL

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

export HAMNIX_BUILD_LOCK_TIMEOUT=900

ELF=build/hamnix-kernel.elf

echo "[test_nscap] (1/3) Build userland (init)"
bash scripts/build_user.sh >/dev/null

echo "[test_nscap] (2/3) Build kernel with /etc/nscap-test marker"
INIT_ELF=build/user/init.elf ENABLE_NSCAP_TEST=1 \
    python3 scripts/build_initramfs.py >/dev/null
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1 || true' EXIT

echo "[test_nscap] (3/3) Boot QEMU and run the nscap self-test"
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

echo "[test_nscap] --- nscap self-test output ---"
grep -E "\[nscap\]" "$LOG" || true
echo "[test_nscap] --- end ---"

fail=0

if [ "$rc" -ne 0 ] && [ "$rc" -ne 124 ]; then
    echo "[test_nscap] FAIL: qemu exited rc=$rc" >&2
    fail=1
fi

# An explicit internal failure is fatal.
if grep -qF "[nscap] FAIL" "$LOG"; then
    echo "[test_nscap] FAIL: kernel self-test reported an internal failure" >&2
    fail=1
fi

check() {
    local label="$1" needle="$2"
    if grep -qF "$needle" "$LOG"; then
        echo "[test_nscap] PASS: $label"
    else
        echo "[test_nscap] FAIL: $label (expected '$needle')" >&2
        fail=1
    fi
}

check "capped ns denied past its memory cap" \
      "[nscap] PASS: capped ns denied past cap"
check "uncapped ns faulted all 32 pages" \
      "[nscap] PASS: uncapped ns faulted all"
check "capped ns residency equals its cap" \
      "[nscap] PASS: capped ns residency"
check "uncapped ns residency tracks all pages" \
      "[nscap] PASS: uncapped ns residency"
check "25% CPU cap yields vruntime factor 4" \
      "[nscap] PASS: 25% CPU cap -> vruntime inflation factor 4"
check "uncapped ns CPU cap is 0" \
      "[nscap] PASS: uncapped ns CPU cap is 0"

# Overall banner: the kernel prints exactly "[nscap] PASS" on its own line
# (after an optional "[NNNNNN] " printk timestamp prefix) only when EVERY
# assertion held. Anchor the match to end-of-line so the per-assertion
# "[nscap] PASS: ..." lines (which have a trailing ": ...") don't satisfy it.
if grep -qE '(^|\] )\[nscap\] PASS$' "$LOG"; then
    echo "[test_nscap] PASS: overall self-test PASS banner"
else
    echo "[test_nscap] FAIL: overall self-test PASS banner missing" >&2
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_nscap] FAIL"
    exit 1
fi

echo "[test_nscap] PASS — a demand-fault past a namespace memory cap is denied" \
     "while an uncapped namespace faults the same pages; the 25% CPU cap" \
     "throttles via a 4x vruntime inflation factor"
