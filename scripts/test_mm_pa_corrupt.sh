#!/usr/bin/env bash
# scripts/test_mm_pa_corrupt.sh — #104 coverage for the buddy-allocator
# free-list-integrity SELF-HEAL guard (mm/page_alloc.ad _pa_get_next), plus a
# regression that the shipped/default boot path never runs the DESTRUCTIVE
# corruption injection that stranded the global pool.
#
# BACKGROUND. page_alloc_corrupt_inject_test() (tests/mm_smoke.ad) scribbles a
# page that is on the order-0 free list and proves the allocator's self-heal
# CATCHES it (logs "[pa-corrupt] ... truncating free list", returns 0) instead
# of #GP-faulting on the wild deref. But truncating the list strands every real
# order-0 entry chained behind the scribbled node — enough, on a KVM/real-HW
# layout, to starve a later region_alloc and fake an `elf: OOM` so [hamsh-alive]
# never prints (the #104 boot-death). So init/main.ad now GATES that injection
# behind /etc/mm-corrupt-test; a shipped/installer boot runs only the
# non-destructive churn half (page_alloc_stress_test).
#
# This gate boots the SAME kernel twice:
#   ON  — with the marker: the injection runs; assert the guard fired and the
#         boot survived (keeps the self-heal path COVERED).
#   OFF — without the marker: assert NO "[pa-corrupt] ... truncating free list"
#         appears — the regression proving a future refactor cannot silently
#         re-strand the global pool on the default boot path.
#
# NOTE on markers: early-boot serial under fast KVM drops mid-burst lines, so
# this gate keys ONLY on the trailing, reliably-flushed markers ("truncating
# free list", "survived corruption injection") and on ABSENCE for the OFF boot.
#
# Pass marker:  [test_pa_corrupt] PASS
# Fail marker:  [test_pa_corrupt] FAIL

. "$(dirname "$0")/_build_lock.sh"
. "$(dirname "$0")/_verdict.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf

echo "[test_pa_corrupt] (1/4) Build userland (init)"
bash scripts/build_user.sh >/dev/null

# HAMNIX_DEFAULT_REAL_DEBIAN=0 keeps the kernel ELF small enough for the
# -kernel/GRUB-ISO boot under -m 256M (see test_mm_pressure.sh for the full
# rationale); the page-allocator self-test is a pure KERNEL test.

boot_kernel() {
    # boot_kernel <logfile>: boot $ELF once, serial -> <logfile>.
    local out="$1"
    local kvm=""
    if [ -e /dev/kvm ] && [ -r /dev/kvm ] && [ -w /dev/kvm ]; then
        kvm="-enable-kvm -cpu host"
    fi
    set +e
    timeout 180s qemu-system-x86_64 \
        $kvm \
        -kernel "$ELF" \
        -smp 1 \
        -nographic \
        -no-reboot \
        -m 256M \
        -monitor none \
        -serial stdio \
        </dev/null > "$out" 2>&1
    local rc=$?
    set -e
    return "$rc"
}

LOG_ON=$(mktemp)
LOG_OFF=$(mktemp)
trap 'rm -f "$LOG_ON" "$LOG_OFF"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1 || true' EXIT

# ---- Boot 1 (ON): marker planted, injection runs, self-heal covered --------
echo "[test_pa_corrupt] (2/4) Build+boot kernel WITH /etc/mm-corrupt-test"
INIT_ELF=build/user/init.elf ENABLE_MM_CORRUPT_TEST=1 HAMNIX_DEFAULT_REAL_DEBIAN=0 \
    python3 scripts/build_initramfs.py >/dev/null
python3 -m compiler.adder compile --target=x86_64-bare-metal init/main.ad -o "$ELF" >/dev/null
rc_on=0; boot_kernel "$LOG_ON" || rc_on=$?

echo "[test_pa_corrupt] --- ON-boot page-allocator self-test output ---"
grep -aE "\[pa-stress\]|\[pa-corrupt\]" "$LOG_ON" || true
echo "[test_pa_corrupt] --- end ---"

# ---- Boot 2 (OFF): default build, injection must NOT run -------------------
echo "[test_pa_corrupt] (3/4) Build+boot DEFAULT kernel (no marker)"
INIT_ELF=build/user/init.elf HAMNIX_DEFAULT_REAL_DEBIAN=0 \
    python3 scripts/build_initramfs.py >/dev/null
python3 -m compiler.adder compile --target=x86_64-bare-metal init/main.ad -o "$ELF" >/dev/null
rc_off=0; boot_kernel "$LOG_OFF" || rc_off=$?

echo "[test_pa_corrupt] --- OFF-boot page-allocator self-test output ---"
grep -aE "\[pa-stress\]|\[pa-corrupt\]" "$LOG_OFF" || true
echo "[test_pa_corrupt] --- end ---"

echo "[test_pa_corrupt] (4/4) Verdict"
# Zero-marker discriminator: a starved/never-booted VM produces NOTHING and
# must read INCONCLUSIVE, not a substantive mm failure.
verdict_boot_gate "test_mm_pa_corrupt" "$LOG_ON" "$rc_on" \
    '\[pa-stress\]|\[pa-corrupt\]'

fail=0
for rc in "$rc_on" "$rc_off"; do
    if [ "$rc" -ne 0 ] && [ "$rc" -ne 124 ]; then
        echo "[test_pa_corrupt] FAIL: qemu exited rc=$rc" >&2
        fail=1
    fi
done

# ON boot: the self-heal guard MUST have fired (detected the scribble), and the
# boot MUST have survived it — this is the self-heal coverage the injection
# exists to provide.
if grep -qaE "\[pa-corrupt\].*truncating free list" "$LOG_ON"; then
    echo "[test_pa_corrupt] PASS: self-heal guard detected the scribbled free page"
else
    echo "[test_pa_corrupt] FAIL: guard did not report the injected corruption" >&2
    fail=1
fi
if grep -qaF "[pa-stress] PASS (survived corruption injection)" "$LOG_ON"; then
    echo "[test_pa_corrupt] PASS: boot survived corruption injection"
else
    echo "[test_pa_corrupt] FAIL: boot did not survive corruption injection" >&2
    fail=1
fi

# OFF boot (regression): the DEFAULT boot path must never run the destructive
# injection — no truncation, no [pa-corrupt] at all. Also its churn half must
# have run (proves the OFF boot actually reached the mm self-tests, so the
# absence below is meaningful and not a never-booted false pass).
if grep -qaF "[pa-stress] churn done" "$LOG_OFF"; then
    echo "[test_pa_corrupt] PASS: default boot reached the page-alloc stress test"
else
    echo "[test_pa_corrupt] FAIL: default boot never reached the stress test" >&2
    fail=1
fi
if grep -qaE "\[pa-corrupt\]|truncating free list" "$LOG_OFF"; then
    echo "[test_pa_corrupt] FAIL: default boot ran the DESTRUCTIVE injection (re-strand regression!)" >&2
    fail=1
else
    echo "[test_pa_corrupt] PASS: default boot did NOT strand the global pool"
fi

# An explicit net-neutrality failure on either boot is fatal.
if grep -qaF "[pa-stress] FAIL" "$LOG_ON" || grep -qaF "[pa-stress] FAIL" "$LOG_OFF"; then
    echo "[test_pa_corrupt] FAIL: churn reported a non-net-neutral leak" >&2
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_pa_corrupt] FAIL"
    exit 1
fi

echo "[test_pa_corrupt] PASS — self-heal guard catches a scribbled free page (marker ON) AND the default boot never strands the global pool (marker OFF)"
