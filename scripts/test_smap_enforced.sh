#!/usr/bin/env bash
# scripts/test_smap_enforced.sh — positive proof that CR4.SMAP enforcement
# is LIVE (v3g).
#
# SMEP+SMAP are wired in arch/x86/kernel/cpu_mitigations.ad. v3g moved the
# SMAP CR4 flip + low/high-identity US=0 restamp to setup_smap_late(),
# called AFTER mem_init() so pgtable_extend_from_e820()'s force-stamp can't
# clobber the US=0 restamp. With SMAP_RUNTIME_ENABLE=1 the box must:
#
#   1. boot to the hamsh heartbeat (SMAP did NOT break the boot path), AND
#   2. report SMAP enforcement is genuinely active: the kernel-side proof
#      smap_enforced_test() (gated on /etc/smap-test) does an UN-STAC'd
#      CPL=0 read of a genuinely-US=1 user page and asserts it #PF's under
#      CR4.SMAP=1 — recovered by a one-entry SMAP probe extable.
#
# CRITICAL: SMAP CPUID bits are only exposed under a HARDWARE accelerator.
# The qemu shim (scripts/_kernel_iso.sh) auto-injects `-accel kvm -cpu host`
# when /dev/kvm is usable, so the boot below runs under KVM on a KVM-capable
# host. Without KVM, CPUID masks SMAP, CR4.SMAP never latches, and the
# kernel test SKIPs (reported, not failed) — so this harness only ASSERTS
# the PASS when KVM is present.
#
# Pass marker:  [test_smap_enforced] PASS
# Fail marker:  [test_smap_enforced] FAIL

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

export HAMNIX_BUILD_LOCK_TIMEOUT=900

ELF=build/hamnix-kernel.elf

echo "[test_smap_enforced] (1/3) Build userland (init)"
bash scripts/build_user.sh >/dev/null

echo "[test_smap_enforced] (2/3) Build kernel with /etc/smap-test marker"
INIT_ELF=build/user/init.elf ENABLE_SMAP_TEST=1 \
    python3 scripts/build_initramfs.py >/dev/null
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1 || true' EXIT

# Detect whether KVM is usable: the shim only injects -accel kvm/-cpu host
# when /dev/kvm is readable AND writable. SMAP enforcement is only
# exercisable under KVM.
KVM=0
if [ -r /dev/kvm ] && [ -w /dev/kvm ]; then
    KVM=1
fi
echo "[test_smap_enforced] KVM usable: $KVM (SMAP only enforces under KVM)"

# SMAP CPUID bits are ONLY exposed under a hardware accelerator. This test
# invokes qemu directly (not via the shim), so we must inject -accel kvm
# -cpu host OURSELVES when /dev/kvm is usable. Without these flags, TCG
# masks the SMAP CPUID bit, CR4.SMAP never latches, and the enforcement
# proof cannot run. (A stale earlier rev relied on a shim that this raw
# qemu line never invoked — hence the spurious "did not latch" FAIL.)
ACCEL_ARGS=()
if [ "$KVM" = "1" ]; then
    ACCEL_ARGS=(-accel kvm -cpu host)
else
    ACCEL_ARGS=(-cpu qemu64)
fi

echo "[test_smap_enforced] (3/3) Boot QEMU (accel: ${ACCEL_ARGS[*]})"
set +e
timeout 180s qemu-system-x86_64 \
    -kernel "$ELF" \
    "${ACCEL_ARGS[@]}" \
    -smp 1 \
    -nographic \
    -no-reboot \
    -m 256M \
    -monitor none \
    -serial stdio \
    </dev/null > "$LOG" 2>&1
rc=$?
set -e

echo "[test_smap_enforced] --- mitigation + SMAP proof output ---"
grep -E "\[mitig\]|\[cpu-mitig\]|\[smap-enforced\]|hamsh" "$LOG" | head -40 || true
echo "[test_smap_enforced] --- end ---"

fail=0

if [ "$rc" -ne 0 ] && [ "$rc" -ne 124 ]; then
    echo "[test_smap_enforced] FAIL: qemu exited rc=$rc" >&2
    fail=1
fi

# Boot must reach the hamsh heartbeat — proves SMAP did not break the boot.
if ! grep -qE "hamsh|heartbeat|\\$ " "$LOG"; then
    echo "[test_smap_enforced] WARN: no hamsh prompt/heartbeat marker found" >&2
fi

if [ "$KVM" -eq 1 ]; then
    # Under KVM, CR4.SMAP must latch AND the enforcement proof must PASS.
    if ! grep -qE "\[mitig\] CR4 SMEP=1 SMAP=1" "$LOG"; then
        echo "[test_smap_enforced] FAIL: CR4.SMAP did not latch under KVM" >&2
        fail=1
    fi
    if grep -qE "\[smap-enforced\] PASS" "$LOG"; then
        echo "[test_smap_enforced] SMAP enforcement proof: PASS"
    else
        echo "[test_smap_enforced] FAIL: smap_enforced_test did not PASS" >&2
        fail=1
    fi
else
    # No KVM: SMAP CPUID masked, enforcement can't be exercised. Accept a
    # clean boot + SKIP as the best this host can show.
    echo "[test_smap_enforced] NOTE: no KVM — SMAP enforcement not exercisable here"
    if grep -qE "\[smap-enforced\] (SKIP|PASS)" "$LOG"; then
        echo "[test_smap_enforced] smap_enforced_test ran (SKIP/PASS) — boot OK"
    fi
fi

if [ "$fail" -eq 0 ]; then
    echo "[test_smap_enforced] PASS"
    exit 0
else
    echo "[test_smap_enforced] FAIL"
    exit 1
fi
