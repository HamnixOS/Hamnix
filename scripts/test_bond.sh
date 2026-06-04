#!/usr/bin/env bash
# scripts/test_bond.sh — native link aggregation (bonding) self-test.
#
# Boots the kernel once with /etc/bond-test planted (ENABLE_BOND_TEST=1).
# init/main.ad at boot:37.bond calls bond_selftest() (drivers/net/bond.ad),
# a fully in-memory test (NO external NIC required) that PROVES the native
# bonding path with REAL slave selection, failover, and round-robin:
#
#   * ENSLAVE: member NICs (ifindex/MAC/link-state) are added to a bond.
#   * MODE 1 active-backup: exactly one slave is active and carries ALL tx;
#     the backups carry zero. Marking the active slave's link DOWN promotes a
#     live backup to active and tx fails over to the newly-promoted slave.
#     With every slave down the bond is carrier-down and tx drops.
#   * MODE 0 balance-rr: tx frames are striped round-robin across the live
#     slaves (4 slaves -> 2 frames each over 8 frames). Downing a slave makes
#     rr SKIP it: subsequent frames land only on live members.
#   * RELEASE: un-enslaving a member shrinks the slave set.
#
# Boot path: a raw 64-bit Hamnix ELF will NOT boot under `qemu -kernel` on
# this host; the _kernel_iso.sh PATH shim (sourced by _build_lock.sh)
# transparently wraps the ELFCLASS64 kernel in a BIOS GRUB ISO, so the
# `-kernel "$ELF"` invocation below boots through the ISO shim.
#
# Pass marker:  [bond] PASS
# Fail marker:  [bond] FAIL / self-test reported FAIL

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

export HAMNIX_BUILD_LOCK_TIMEOUT="${HAMNIX_BUILD_LOCK_TIMEOUT:-900}"

ELF=build/hamnix-kernel.elf

echo "[test_bond] (1/3) Build userland (init)"
bash scripts/build_user.sh >/dev/null

echo "[test_bond] (2/3) Build kernel with /etc/bond-test marker"
INIT_ELF=build/user/init.elf ENABLE_BOND_TEST=1 \
    python3 scripts/build_initramfs.py >/dev/null
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

LOG=$(mktemp)
# Restore the default initramfs afterwards + clean up the log.
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1 || true' EXIT

echo "[test_bond] (3/3) Boot QEMU"
set +e
timeout 320s qemu-system-x86_64 \
    -kernel "$ELF" \
    -smp 1 \
    -nographic -no-reboot -m 256M -monitor none -serial stdio \
    > "$LOG" 2>&1 < /dev/null
rc=$?
set -e

echo "[test_bond] --- captured (bond lines) ---"
grep -E '\[bond\]|\[boot:37.bond\]' "$LOG" || true
echo "[test_bond] --- end ---"

fail=0

if [ "$rc" -ne 0 ] && [ "$rc" -ne 124 ]; then
    echo "[test_bond] FAIL: qemu exited rc=$rc" >&2
    fail=1
fi

if grep -qF "[bond] FAIL" "$LOG"; then
    echo "[test_bond] FAIL: kernel self-test reported an internal failure" >&2
    fail=1
fi
if grep -qF "[boot:37.bond] FAIL" "$LOG"; then
    echo "[test_bond] FAIL: boot gate reported FAIL" >&2
    fail=1
fi

check() {
    local label="$1" needle="$2"
    if grep -qF "$needle" "$LOG"; then
        echo "[test_bond] PASS: $label"
    else
        echo "[test_bond] FAIL: $label (expected '$needle')" >&2
        fail=1
    fi
}

check "self-test ran"               "[bond] self-test start"
check "enslave active-backup"       "[bond] enslave 3 slaves (mode active-backup) OK"
check "active-backup initial"       "[bond] active-backup initial active = slave 0 OK"
check "active-backup tx routes"     "[bond] active-backup tx routes to active slave 0 (5 frames) OK"
check "failover promotes backup"    "[bond] failover: active slave 0 down -> promoted slave 1 OK"
check "post-failover tx routes"     "[bond] post-failover tx routes to promoted slave 1 OK"
check "all-down tx drops"           "[bond] all-slaves-down tx drops (no carrier) OK"
check "enslave balance-rr"          "[bond] enslave 4 slaves (mode balance-rr) OK"
check "balance-rr cycles"           "[bond] balance-rr cycles 0,1,2,3,0,1,2,3 across live slaves OK"
check "balance-rr even"             "[bond] balance-rr even distribution (2 frames each) OK"
check "balance-rr skips down"       "[bond] balance-rr skips down slave, distributes to live {0,2,3} OK"
check "release member"              "[bond] release member (slave set shrinks) OK"
check "bond PASS banner"            "[bond] PASS"
check "boot gate PASS"              "[boot:37.bond] PASS"

if [ "$fail" -ne 0 ]; then
    echo "[test_bond] FAIL"
    exit 1
fi

echo "[test_bond] PASS — native link aggregation (bonding): mode-1 active-backup routes all tx to the single active slave and fails over to a live backup when the active slave's link drops; mode-0 balance-rr stripes tx round-robin across live slaves (2 frames each over 4 members) and skips a down slave; enslave/release mutate the member set — all verified with genuinely-computed slave selection"
