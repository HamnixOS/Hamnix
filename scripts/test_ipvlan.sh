#!/usr/bin/env bash
# scripts/test_ipvlan.sh — native ipvlan (Linux drivers/net/ipvlan/) virtual-
# link self-test.
#
# Boots the kernel once with /etc/ipvlan-test planted (ENABLE_IPVLAN_TEST=1).
# init/main.ad at boot:37.ipvlan calls ipvlan_selftest() (drivers/net/
# ipvlan.ad), a fully in-memory test (NO external NIC required) that PROVES the
# core ipvlan semantics:
#
#   * Multiple virtual interfaces (slaves) over ONE parent netdev that SHARE the
#     parent's MAC (the defining ipvlan property, vs macvlan's distinct MACs);
#     a duplicate IP on the same parent is rejected.
#   * L2 mode: the parent switches on the destination MAC (== the shared parent
#     MAC) then the destination IP — a frame to the parent MAC + a slave's IP is
#     delivered to that slave (proved for two slaves sharing one MAC); a
#     broadcast dst MAC floods to all slaves; a frame to the parent MAC with an
#     unknown dst IP is dropped; a frame whose dst MAC is NOT the parent MAC is
#     rejected.
#   * L3 mode: steering is PURELY on destination IP — the dst MAC is irrelevant
#     (a frame with a non-parent dst MAC still routes by IP); there is no
#     broadcast flood; a packet whose dst IP matches no slave is dropped.
#
# Boot path: a raw 64-bit Hamnix ELF will NOT boot under `qemu -kernel` on this
# host; the _kernel_iso.sh PATH shim (sourced by _build_lock.sh) transparently
# wraps the ELFCLASS64 kernel in a BIOS GRUB ISO, so the `-kernel "$ELF"`
# invocation below boots through the ISO shim.
#
# Pass marker:  [ipvlan] PASS
# Fail marker:  [ipvlan] FAIL / self-test reported FAIL

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

export HAMNIX_BUILD_LOCK_TIMEOUT="${HAMNIX_BUILD_LOCK_TIMEOUT:-900}"

ELF=build/hamnix-kernel.elf

echo "[test_ipvlan] (1/3) Build userland (init)"
bash scripts/build_user.sh >/dev/null

echo "[test_ipvlan] (2/3) Build kernel with /etc/ipvlan-test marker"
INIT_ELF=build/user/init.elf ENABLE_IPVLAN_TEST=1 \
    python3 scripts/build_initramfs.py >/dev/null
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

LOG=$(mktemp)
# Restore the default initramfs afterwards + clean up the log.
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1 || true' EXIT

echo "[test_ipvlan] (3/3) Boot QEMU"
set +e
timeout 320s qemu-system-x86_64 \
    -kernel "$ELF" \
    -smp 1 \
    -nographic -no-reboot -m 256M -monitor none -serial stdio \
    > "$LOG" 2>&1 < /dev/null
rc=$?
set -e

echo "[test_ipvlan] --- captured (ipvlan lines) ---"
grep -E '\[ipvlan\]|\[boot:37.ipvlan\]' "$LOG" || true
echo "[test_ipvlan] --- end ---"

fail=0

if [ "$rc" -ne 0 ] && [ "$rc" -ne 124 ]; then
    echo "[test_ipvlan] FAIL: qemu exited rc=$rc" >&2
    fail=1
fi

if grep -qF "[ipvlan] FAIL" "$LOG"; then
    echo "[test_ipvlan] FAIL: kernel self-test reported an internal failure" >&2
    fail=1
fi
if grep -qF "[boot:37.ipvlan] FAIL" "$LOG"; then
    echo "[test_ipvlan] FAIL: boot gate reported FAIL" >&2
    fail=1
fi

check() {
    local label="$1" needle="$2"
    if grep -qF "$needle" "$LOG"; then
        echo "[test_ipvlan] PASS: $label"
    else
        echo "[test_ipvlan] FAIL: $label (expected '$needle')" >&2
        fail=1
    fi
}

check "self-test ran"             "[ipvlan] self-test start"
check "L2 slave add"              "[ipvlan] PASS l2-slave-add"
check "reject duplicate IP"       "[ipvlan] PASS reject-duplicate-ip"
check "L2 switch to slave2"       "[ipvlan] PASS l2-switch-to-slave2"
check "L2 switch to slave1"       "[ipvlan] PASS l2-switch-to-slave1"
check "L2 unknown IP dropped"     "[ipvlan] PASS l2-unknown-ip-dropped"
check "L2 broadcast flood"        "[ipvlan] PASS l2-broadcast-flood"
check "L2 wrong-MAC rejected"     "[ipvlan] PASS l2-wrong-mac-rejected"
check "L3 slave add"              "[ipvlan] PASS l3-slave-add"
check "L3 route by IP only"       "[ipvlan] PASS l3-route-by-ip-only"
check "L3 route to slave1"        "[ipvlan] PASS l3-route-to-slave1"
check "L3 unknown IP dropped"     "[ipvlan] PASS l3-unknown-ip-dropped-no-flood"
check "L3 no flood routes by IP"  "[ipvlan] PASS l3-no-flood-routes-by-ip"
check "ipvlan PASS banner"        "[ipvlan] PASS"
check "boot gate PASS"            "[boot:37.ipvlan] PASS"

if [ "$fail" -ne 0 ]; then
    echo "[test_ipvlan] FAIL"
    exit 1
fi

echo "[test_ipvlan] PASS — native ipvlan: multiple virtual interfaces over one parent that share the parent's MAC; L2 mode switches on the shared MAC then destination IP (delivering to the slave owning the dst IP, flooding broadcast, dropping an unknown dst IP, rejecting a wrong dst MAC); L3 mode routes purely on destination IP (MAC irrelevant, no flood) and drops a packet whose dst IP matches no slave"
