#!/usr/bin/env bash
# scripts/test_firewall.sh — native stateful packet-filter firewall
# (iptables/nftables-equivalent) with a Plan-9 control surface.
#
# Boots the kernel once with /etc/firewall-test planted
# (ENABLE_FIREWALL_TEST=1); init/main.ad at boot:37.fw calls
# firewall_selftest() (drivers/net/firewall.ad), which drives the REAL
# _fw_evaluate verdict engine — the EXACT function the ip_rx (INGRESS)
# and ip_send (EGRESS) enforcement hooks call — NOT a parallel mock.
#
# UNFORGEABLE assertions the kernel self-test prints as [firewall] lines,
# all of which this script requires:
#   * a "drop in tcp dport 23" rule DROPs a matching inbound packet
#   * that rule's per-rule HIT COUNTER increments
#   * a non-matching inbound tcp dport-80 packet is ACCEPTed (default
#     policy ACCEPT)
#   * STATEFUL: under default policy DROP + an "allow inbound
#     established" rule, a COLD inbound SYN-ACK (no tracked flow) is
#     DROPped, but after an outbound SYN seeds conntrack the RETURNING
#     SYN-ACK on the same 4-tuple is ACCEPTed — the established reply a
#     bare default-drop-inbound policy would otherwise block
#   * an UNRELATED inbound flow still DROPs (the established rule is keyed
#     to the tracked tuple, not a blanket allow)
#   * the [firewall] PASS banner
#
# Proving the SAME default-drop-inbound policy DROPs a cold SYN-ACK but
# ACCEPTs the established reply is what makes this a real stateful
# firewall and not a static ACL.
#
# Boot path: a raw 64-bit Hamnix ELF will NOT boot under `qemu -kernel`
# on this host; the _kernel_iso.sh PATH shim (sourced by _build_lock.sh)
# transparently wraps the ELFCLASS64 kernel in a BIOS GRUB ISO, so the
# `-kernel "$ELF"` invocation below boots through the ISO shim.
#
# Pass marker:  [test_firewall] PASS
# Fail marker:  [test_firewall] FAIL

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

export HAMNIX_BUILD_LOCK_TIMEOUT=900

ELF=build/hamnix-kernel.elf

echo "[test_firewall] (1/3) Build userland (init)"
bash scripts/build_user.sh >/dev/null

echo "[test_firewall] (2/3) Build kernel with /etc/firewall-test marker"
INIT_ELF=build/user/init.elf ENABLE_FIREWALL_TEST=1 \
    python3 scripts/build_initramfs.py >/dev/null
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1 || true' EXIT

echo "[test_firewall] (3/3) Boot QEMU and run the firewall self-test"
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

echo "[test_firewall] --- firewall self-test output ---"
grep -E "\[firewall\]" "$LOG" || true
echo "[test_firewall] --- end ---"

fail=0

if [ "$rc" -ne 0 ] && [ "$rc" -ne 124 ]; then
    echo "[test_firewall] FAIL: qemu exited rc=$rc" >&2
    fail=1
fi

# Any explicit internal failure is fatal.
if grep -qF "[firewall] FAIL" "$LOG"; then
    echo "[test_firewall] FAIL: kernel self-test reported an internal failure" >&2
    fail=1
fi

check() {
    local label="$1" needle="$2"
    if grep -qF "$needle" "$LOG"; then
        echo "[test_firewall] PASS: $label"
    else
        echo "[test_firewall] FAIL: $label (expected '$needle')" >&2
        fail=1
    fi
}

check "inbound tcp dport23 dropped"          "[firewall] inbound tcp dport23 -> DROP OK"
check "rule0 hit counter incremented"        "[firewall] rule0 hit counter incremented OK"
check "inbound tcp dport80 accepted"         "[firewall] inbound tcp dport80 -> ACCEPT OK"
check "cold inbound SYN-ACK dropped"         "[firewall] cold inbound SYN-ACK -> DROP (no state) OK"
check "outbound SYN accepted + tracked"      "[firewall] outbound SYN -> ACCEPT (seeds conntrack) OK"
check "conntrack tracks the flow"            "[firewall] conntrack now tracks 1 flow OK"
check "established reply accepted"           "[firewall] established reply SYN-ACK -> ACCEPT OK"
check "unrelated inbound flow dropped"       "[firewall] unrelated inbound flow -> DROP OK"
check "firewall self-test PASS banner"       "[firewall] PASS"

if [ "$fail" -ne 0 ]; then
    echo "[test_firewall] FAIL"
    exit 1
fi

echo "[test_firewall] PASS — a DROP rule drops a matching packet (hit counter bumps) while a non-matching packet is ACCEPTed, and stateful conntrack lets an established reply through a default-drop-inbound policy"
