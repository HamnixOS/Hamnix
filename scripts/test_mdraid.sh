#!/usr/bin/env bash
# scripts/test_mdraid.sh — native software-RAID (md) self-test.
#
# Boots the kernel once with /etc/mdraid-test planted
# (ENABLE_MDRAID_TEST=1). init/main.ad at boot:37.md calls md_selftest()
# (drivers/block/md.ad), which registers DEDICATED in-kernel backing
# ramdisks ("mdback0".."mdback3") and PROVES the native software-RAID
# RAID0 (stripe) + RAID1 (mirror, degraded-mode) targets:
#
#   * RAID0: a write through the striped array routes each virtual sector
#     to the correct member at the right per-member offset (vLBA5 ->
#     member1, vLBA8 -> member0 chunk1), an untouched member stays clean,
#     and a BOUNDARY-STRADDLING 2-sector write at vLBA3..4 is SPLIT — its
#     first sector lands on member0 and its second on member1 — and reads
#     back byte-identical.
#   * RAID1: a single write fans out to BOTH members (verified by raw
#     per-member reads) and reads round-trip through the mirror.
#   * RAID1 DEGRADED: after one member is marked Faulty, a write reaches
#     only the survivor (the failed member is skipped) and a read serves
#     from the survivor — the data still round-trips.
#
# The self-test needs NO external disk — it backs everything onto its own
# in-kernel ramdisks, so the boot is fully deterministic.
#
# Boot path: a raw 64-bit Hamnix ELF will NOT boot under `qemu -kernel`
# on this host; the _kernel_iso.sh PATH shim (sourced by _build_lock.sh)
# transparently wraps the ELFCLASS64 kernel in a BIOS GRUB ISO, so the
# `-kernel "$ELF"` invocation below boots through the ISO shim.
#
# Pass marker:  [mdraid] PASS
# Fail marker:  [mdraid] FAIL / self-test reported FAIL

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

export HAMNIX_BUILD_LOCK_TIMEOUT="${HAMNIX_BUILD_LOCK_TIMEOUT:-900}"

ELF=build/hamnix-kernel.elf

echo "[test_mdraid] (1/3) Build userland (init)"
bash scripts/build_user.sh >/dev/null

echo "[test_mdraid] (2/3) Build kernel with /etc/mdraid-test marker"
INIT_ELF=build/user/init.elf ENABLE_MDRAID_TEST=1 \
    python3 scripts/build_initramfs.py >/dev/null
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

LOG=$(mktemp)
# Restore the default initramfs afterwards + clean up the log.
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1 || true' EXIT

echo "[test_mdraid] (3/3) Boot QEMU"
set +e
timeout 320s qemu-system-x86_64 \
    -kernel "$ELF" \
    -smp 1 \
    -nographic -no-reboot -m 256M -monitor none -serial stdio \
    > "$LOG" 2>&1 < /dev/null
rc=$?
set -e

echo "[test_mdraid] --- captured (mdraid lines) ---"
grep -E '\[mdraid\]' "$LOG" || true
echo "[test_mdraid] --- end ---"

fail=0

if [ "$rc" -ne 0 ] && [ "$rc" -ne 124 ]; then
    echo "[test_mdraid] FAIL: qemu exited rc=$rc" >&2
    fail=1
fi

if grep -qF "[mdraid] FAIL" "$LOG"; then
    echo "[test_mdraid] FAIL: kernel self-test reported an internal failure" >&2
    fail=1
fi
if grep -qF "[mdraid] self-test reported FAIL" "$LOG"; then
    echo "[test_mdraid] FAIL: self-test returned non-zero" >&2
    fail=1
fi

check() {
    local label="$1" needle="$2"
    if grep -qF "$needle" "$LOG"; then
        echo "[test_mdraid] PASS: $label"
    else
        echo "[test_mdraid] FAIL: $label (expected '$needle')" >&2
        fail=1
    fi
}

check "self-test ran"                "[mdraid] self-test start"
check "raid0 stripe route member1"   "[mdraid] raid0: vLBA5 -> member1 mlba1 OK"
check "raid0 member0 untouched"      "[mdraid] raid0: member0 mlba1 untouched OK"
check "raid0 stripe route member0"   "[mdraid] raid0: vLBA8 -> member0 mlba4 OK"
check "raid0 straddle half0"         "[mdraid] raid0: straddle sector0 -> member0 mlba3 OK"
check "raid0 straddle half1"         "[mdraid] raid0: straddle sector1 -> member1 mlba0 OK"
check "raid0 straddle readback"      "[mdraid] raid0: straddle reads back byte-identical OK"
check "raid1 write member0"          "[mdraid] raid1: write landed on member0 (mdback2) OK"
check "raid1 write member1"          "[mdraid] raid1: write landed on member1 (mdback3) OK"
check "raid1 read round-trip"        "[mdraid] raid1: read round-trips through mirror OK"
check "raid1 degraded write"         "[mdraid] raid1 degraded: write reached survivor OK"
check "raid1 degraded skip failed"   "[mdraid] raid1 degraded: failed member skipped on write OK"
check "raid1 degraded read"          "[mdraid] raid1 degraded: read round-trips via survivor OK"
check "mdraid PASS"                  "[mdraid] PASS"

if [ "$fail" -ne 0 ]; then
    echo "[test_mdraid] FAIL"
    exit 1
fi

echo "[test_mdraid] PASS — native software RAID: RAID0 stripe routing (with boundary-straddle split), RAID1 mirror fan-out, and RAID1 degraded-mode survivor round-trip all verified"
