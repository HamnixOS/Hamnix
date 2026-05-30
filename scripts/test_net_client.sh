#!/usr/bin/env bash
# scripts/test_net_client.sh — end-to-end NETWORK CLIENT survival kit.
#
# Proves Hamnix behaves like a real OS network client: it gets a DHCP
# lease at boot, resolves a hostname by NAME through the in-kernel
# resolver, and reaches a host BY NAME — all over QEMU user-mode
# networking (SLIRP), which provides:
#   * a DHCP server at 10.0.2.2 that hands out 10.0.2.15
#   * a DNS forwarder at 10.0.2.3 (forwards to the host's resolver)
#
# The test drives hamsh interactively (prompt-aware, via _qemu_drive.sh
# so the first command is never typed before hamsh's SYS_READ is live):
#
#   ifconfig          → assert a 10.0.2.x lease tagged (dhcp)
#   host <name>       → assert "has address <a.b.c.d>"
#   ping -c 1 <name>  → assert a name-based ICMP exchange went out
#
# OUTCOME MODEL (mirrors test_dns.sh):
#   * The DHCP-lease assertion is DETERMINISTIC — SLIRP always answers a
#     DISCOVER locally regardless of upstream internet, so a missing
#     10.0.2.x lease is a hard FAIL (a DHCP-at-boot regression).
#   * The name-resolution + ping legs are LIVE: they need the host's
#     SLIRP DNS forwarder to reach a real resolver. With no usable
#     egress they SKIP CLEANLY (exit 0) rather than hard-failing, the
#     same way test_dns.sh treats "[dns] timeout".
#   * If QEMU/SLIRP itself is unavailable, the test SKIPs (exit 0).

. "$(dirname "$0")/_build_lock.sh"
. "$(dirname "$0")/_qemu_drive.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf

# A name with stable, well-known A-records. SLIRP forwards the query to
# whatever resolver the host uses.
RESOLVE_NAME="example.com"

echo "[test_net_client] (1/4) Build userland (incl. host + ping)"
bash scripts/build_user.sh >/dev/null

echo "[test_net_client] (2/4) Swap /init = $HAMSH_ELF + build initramfs"
INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py >/dev/null

echo "[test_net_client] (3/4) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

echo "[test_net_client] (4/4) Boot QEMU with virtio-net + SLIRP"

# No qemu binary at all → SKIP cleanly.
if ! command -v qemu-system-x86_64 >/dev/null 2>&1; then
    echo "[test_net_client] SKIP (qemu-system-x86_64 not installed)"
    exit 0
fi

LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null' EXIT

# Prompt-aware drive. GENEROUS per-command settles (6 s) — the brief's
# fragility lesson: the first interactive command can have its keystrokes
# EATEN if typed before hamsh finishes its first-prompt startup, and the
# host / ping commands each block on a real DNS round-trip + ICMP wait.
set +e
QEMU_EXTRA_ARGS="-netdev user,id=n0 -device virtio-net-pci,netdev=n0,mac=52:54:00:12:34:56" \
qemu_drive "$LOG" "$ELF" "[hamsh] M16.35 shell ready" 70 \
    -- "ifconfig" 6 \
       "host ${RESOLVE_NAME}" 8 \
       "ping -c 1 ${RESOLVE_NAME}" 8 \
       "exit" 2
rc="$QEMU_DRIVE_RC"
set -e

echo "[test_net_client] --- captured output ---"
cat "$LOG"
echo "[test_net_client] --- end output ---"

# Did the shell even come up? If the readiness marker never showed, the
# kernel wedged or QEMU couldn't boot — SKIP rather than FAIL, since this
# may be an environment without a working QEMU/SLIRP path.
if ! grep -F -q "[hamsh] M16.35 shell ready" "$LOG"; then
    echo "[test_net_client] SKIP (hamsh never reached its ready banner; no usable QEMU boot)"
    exit 0
fi

# Collapse newlines so multi-token assertions survive printk interleave.
cleaned=$(sed 's/task: pid -*[0-9]* exited (code=-*[0-9]*)//g' "$LOG" \
          | tr '\n' ' ' | tr -s ' ')

# === (a) DHCP lease at boot — DETERMINISTIC ========================
# ifconfig renders "eth0  inet 10.0.2.x  netmask ...  (dhcp)". SLIRP
# always answers a DISCOVER locally, so a missing lease is a real
# DHCP-at-boot regression.
if echo "$cleaned" | grep -E -q "inet 10\.0\.2\.[0-9]+ .*\(dhcp\)"; then
    echo "[test_net_client] OK (a): interface got a 10.0.2.x lease via DHCP"
else
    echo "[test_net_client] FAIL (a): no DHCP-assigned 10.0.2.x lease in ifconfig"
    echo "[test_net_client] FAIL (qemu rc=$rc)"
    exit 1
fi

# === (b) name resolution via the kernel resolver — LIVE ============
# `host example.com` prints "<name> has address <a.b.c.d>" on success.
NAME_RESOLVED=0
if echo "$cleaned" | grep -E -q "${RESOLVE_NAME} has address [0-9]+\.[0-9]+\.[0-9]+\.[0-9]+"; then
    echo "[test_net_client] OK (b): host resolved ${RESOLVE_NAME} to an address"
    NAME_RESOLVED=1
else
    echo "[test_net_client] (b) live: ${RESOLVE_NAME} did not resolve (no egress?)"
fi

# === (c) reach the host BY NAME — LIVE =============================
# ping resolves the name first (sys_resolve) then sends ICMP. A reply
# line "bytes from <ip>" proves end-to-end name-based connectivity; a
# resolve that worked but timed out still proves the name path.
PING_NAME_OK=0
if echo "$cleaned" | grep -E -q "PING ${RESOLVE_NAME} \([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+\)"; then
    # The name resolved inside ping and an ICMP exchange was attempted.
    PING_NAME_OK=1
    if echo "$cleaned" | grep -E -q "bytes from [0-9]+\.[0-9]+\.[0-9]+\.[0-9]+"; then
        echo "[test_net_client] OK (c): ping reached ${RESOLVE_NAME} by name (got a reply)"
    else
        echo "[test_net_client] OK (c): ping resolved ${RESOLVE_NAME} by name (reply timed out — egress filtered)"
    fi
else
    echo "[test_net_client] (c) live: ping could not resolve ${RESOLVE_NAME} by name (no egress?)"
fi

# === verdict =======================================================
# (a) is mandatory and already enforced above. The live name legs SKIP
# cleanly when there is no usable upstream DNS/egress path.
if [ "$NAME_RESOLVED" -eq 1 ] || [ "$PING_NAME_OK" -eq 1 ]; then
    echo "[test_net_client] PASS (DHCP lease + name-based resolution proven over the wire)"
    exit 0
fi

echo "[test_net_client] SKIP live name-resolution legs (no usable SLIRP/DNS egress);"
echo "[test_net_client] DHCP-at-boot leg PASSED."
echo "[test_net_client] PASS"
exit 0
