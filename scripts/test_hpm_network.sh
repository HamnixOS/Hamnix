#!/usr/bin/env bash
# scripts/test_hpm_network.sh — end-to-end test for `hpm refresh`
# against the canonical hosted repo `https://255.one/` from a fresh
# QEMU/SLIRP boot. This is the network-side counterpart to test_hpm.sh
# (which exercises hpm against a file:// fixture and proves the CLI
# semantics in isolation from the network stack).
#
# WHY THIS EXISTS
#
# User report: booting the live ISO in GNOME Boxes (QEMU/SLIRP user-mode
# networking under the hood) and running `hpm refresh` printed
#
#     hpm: cannot resolve 255.one
#     hpm: refresh failed
#
# Root cause: etc/rc.boot unconditionally clobbered the kernel's DHCP-
# bound config with a hard-coded 10.250.10.99 / DNS=10.250.10.1, which
# is not reachable from a SLIRP guest (the SLIRP-emulated DNS lives at
# 10.0.2.3). DNS queries went to the unreachable 10.250.10.1 and never
# came back. Fixed by dropping the unconditional override in rc.boot
# (commit "rc.boot: drop unconditional static-IP override; let DHCP
# win"). This test pins the regression: a fresh boot with SLIRP
# networking must successfully refresh the hosted repo.
#
# WHAT THE TEST DOES
#
#   1. Build the userland + a hamsh-as-init initramfs (so the box
#      lands in the shell after rc.boot finishes, exactly as a real
#      live-ISO boot would).
#   2. Boot QEMU with a virtio-net NIC backed by SLIRP user-mode
#      networking (the SLIRP gateway 10.0.2.2 forwards out to the
#      host's network stack — same path GNOME Boxes uses).
#   3. From the shell, run a quick `ifconfig` + `ping 1.1.1.1` to
#      prove the network is alive, then run `hpm refresh` against
#      the default repo (https://255.one/) and assert the index is
#      fetched + parsed.
#
# REQUIRED MARKERS for PASS:
#   * "[dhcp] got ip=10.0.2.15"          — DHCP succeeded
#   * "  (dhcp)" in ifconfig output      — kernel cfg_src=dhcp (NOT
#                                          overridden by rc.boot)
#   * "hpm: refreshed index from https://255.one/" OR equivalent
#                                        — index fetched + parsed
#   * NO "TRAP: vector"                  — no panic
#
# NETWORK-DEPENDENCY POLICY
#
# This test depends on https://255.one/ being reachable from the host's
# network. If the host has no internet (CI sandbox without egress, or
# the upstream is down) the test PASSes as a SKIP with a NOTE — the
# regression we're guarding is the rc.boot override clobbering DHCP,
# which is provable on its own from the DHCP-state markers. A fully-
# offline CI machine still sees DHCP land at 10.0.2.15 and ifconfig
# report (dhcp); only the final hpm refresh step gets skipped.

. "$(dirname "$0")/_build_lock.sh"
. "$(dirname "$0")/_qemu_drive.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf

echo "[test_hpm_network] (1/3) Build userland + hamsh-as-init initramfs"
bash scripts/build_user.sh >/dev/null
if [ ! -x "build/user/hpm.elf" ]; then
    echo "[test_hpm_network] FAIL: build/user/hpm.elf missing after build"
    exit 1
fi
if [ ! -x "build/user/ifconfig.elf" ]; then
    echo "[test_hpm_network] FAIL: build/user/ifconfig.elf missing after build"
    exit 1
fi
# INIT_ELF=hamsh so /init runs hamsh /etc/rc.boot directly (live-ISO
# shape). After rc.boot exits the user drops to the interactive prompt
# and we can drive `ifconfig` / `hpm refresh` over the serial console.
INIT_ELF="$HAMSH_ELF" \
    python3 scripts/build_initramfs.py >/dev/null

echo "[test_hpm_network] (2/3) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

echo "[test_hpm_network] (3/3) Boot QEMU + drive hpm refresh"
LOG=$(mktemp /tmp/test-hpm-network.XXXXXX.log)
# Keep the log on PASS too (HPM_KEEP_LOG=1) — debugging this test is
# painful without it. The init.elf restore still runs unconditionally.
trap '[ "${HPM_KEEP_LOG:-0}" = 1 ] || rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1 || true' EXIT

# virtio-net + SLIRP: gateway 10.0.2.2, DHCP server 10.0.2.2,
# DNS server 10.0.2.3 (emulated, forwards to the host's resolver),
# guest gets 10.0.2.15. Identical to what GNOME Boxes uses.
export QEMU_EXTRA_ARGS="-netdev user,id=n0 -device virtio-net-pci,netdev=n0,mac=52:54:00:12:34:56"

set +e
qemu_drive "$LOG" "$ELF" "[hamsh] M16.35 shell ready" 180 \
    -- "echo HPM_NET_START"                          2 \
       "ifconfig"                                     3 \
       "echo HPM_NET_IFCONFIG_DONE"                   2 \
       "/bin/ping -c 2 -i 200 10.0.2.2"               6 \
       "echo HPM_NET_PING_GATEWAY_DONE"               2 \
       "/bin/ping -c 2 -i 200 1.1.1.1"                8 \
       "echo HPM_NET_PING_INTERNET_DONE"              2 \
       "hpm refresh"                                  20 \
       "echo HPM_NET_REFRESH_DONE"                    2 \
       "exit"                                         2
rc="$QEMU_DRIVE_RC"
set -e

echo "[test_hpm_network] --- captured (relevant lines) ---"
grep -E '\[dhcp\]|\[icmp\]|\(dhcp\)|\(static\)|bytes from|ping statistics|hpm:|HPM_NET_|cannot resolve|refresh' "$LOG" || true
echo "[test_hpm_network] --- end ---"

fail=0

# 1. NO kernel panic / trap.
if grep -F -q "TRAP: vector" "$LOG"; then
    echo "[test_hpm_network] FAIL: kernel reported a CPU exception"
    grep -F "TRAP: vector" "$LOG" | head -5 || true
    fail=1
else
    echo "[test_hpm_network] OK: no kernel TRAP / panic"
fi

# 2. Shell came up (boot didn't wedge).
if ! grep -F -q "HPM_NET_START" "$LOG"; then
    echo "[test_hpm_network] FAIL: shell never accepted the first command"
    echo "[test_hpm_network] --- last 100 lines of log ---"
    tail -n 100 "$LOG"
    exit 1
fi

# 3. DHCP succeeded — the regression-guard pre-condition. If this
# fails the test cannot meaningfully proceed.
if grep -F -q "[dhcp] got ip=10.0.2.15" "$LOG"; then
    echo "[test_hpm_network] OK: DHCP got ip=10.0.2.15"
else
    echo "[test_hpm_network] FAIL: DHCP did NOT bind 10.0.2.15"
    fail=1
fi

# 4. THE CORE ASSERTION: ifconfig output must show "(dhcp)" as the
# cfg source, not "(static)". This is exactly the regression we are
# guarding — the old rc.boot would have flipped this to "(static)".
ifconfig_block=$(sed -n '/HPM_NET_START/,/HPM_NET_IFCONFIG_DONE/p' "$LOG")
if echo "$ifconfig_block" | grep -F -q "(dhcp)"; then
    echo "[test_hpm_network] OK: ifconfig reports cfg source = (dhcp)"
else
    echo "[test_hpm_network] FAIL: ifconfig does NOT show (dhcp) —"
    echo "[test_hpm_network]       rc.boot may be clobbering DHCP again"
    fail=1
fi
if echo "$ifconfig_block" | grep -F -q "10.250.10.99"; then
    echo "[test_hpm_network] FAIL: ifconfig still shows the hard-coded"
    echo "[test_hpm_network]       10.250.10.99 — rc.boot static override"
    echo "[test_hpm_network]       has crept back in"
    fail=1
fi

# 5. Gateway ping (10.0.2.2) — proves the IP / ICMP stack works on
# the freshly-DHCP-bound config.
gw_ping_block=$(sed -n '/HPM_NET_IFCONFIG_DONE/,/HPM_NET_PING_GATEWAY_DONE/p' "$LOG")
if echo "$gw_ping_block" | grep -E -q "bytes from 10.0.2.2: icmp_seq="; then
    echo "[test_hpm_network] OK: ping 10.0.2.2 (SLIRP gateway) replied"
else
    echo "[test_hpm_network] MISS: gateway ping did not reply (SLIRP"
    echo "[test_hpm_network]       ICMP-forward sometimes denied by host)"
    # Not a hard fail — SLIRP's ICMP forwarding requires the host's
    # net.ipv4.ping_group_range to include the QEMU caller. The test
    # treats it as advisory.
fi

# 6. Internet ping (1.1.1.1) — proves the network has egress to the
# real internet via SLIRP. If this is missing the host has no
# outbound connectivity; downgrade hpm refresh to SKIP.
internet_block=$(sed -n '/HPM_NET_PING_GATEWAY_DONE/,/HPM_NET_PING_INTERNET_DONE/p' "$LOG")
internet_alive=0
if echo "$internet_block" | grep -E -q "bytes from 1.1.1.1: icmp_seq="; then
    echo "[test_hpm_network] OK: ping 1.1.1.1 replied (internet reachable)"
    internet_alive=1
else
    echo "[test_hpm_network] NOTE: ping 1.1.1.1 didn't reply — host may"
    echo "[test_hpm_network]       have no internet egress; hpm refresh"
    echo "[test_hpm_network]       step downgraded to SKIP-or-pass"
fi

# 7. hpm refresh — the user-visible goal. The block runs against
# https://255.one/ (the hpm default). Looking for the success message
# or for the index dump that follows on a healthy refresh. The repo
# ships 5 packages today (hpm-hello + the hamnix-* base set) — that's
# the manual-test acceptance criterion the brief calls out, so we
# also confirm a 5-package payload landed when the success line
# carries a package count.
refresh_block=$(sed -n '/HPM_NET_PING_INTERNET_DONE/,/HPM_NET_REFRESH_DONE/p' "$LOG")
refresh_ok=0
if echo "$refresh_block" | grep -E -q "refreshed index from https://255\.one/?"; then
    refresh_ok=1
elif echo "$refresh_block" | grep -E -q "hpm: refresh OK"; then
    refresh_ok=1
fi
# Soft check: the repo today carries 5 packages. The exact count
# may change as 255.one grows; we ONLY report a mismatch as a NOTE
# so this test doesn't false-fail when packages are legitimately
# added or removed upstream.
if echo "$refresh_block" | grep -E -q "5 packages"; then
    echo "[test_hpm_network] OK: hpm reports 5 packages from https://255.one/"
elif echo "$refresh_block" | grep -E -q "[0-9]+ packages"; then
    actual_n=$(echo "$refresh_block" | grep -oE "[0-9]+ packages" | head -1)
    echo "[test_hpm_network] NOTE: hpm reports '$actual_n' (brief expects 5)"
fi
refresh_resolved=0
if echo "$refresh_block" | grep -F -q "cannot resolve 255.one"; then
    # The exact symptom the user reported. If we see this, DNS is
    # broken and the bug has regressed.
    echo "[test_hpm_network] FAIL: hpm reported 'cannot resolve 255.one'"
    echo "[test_hpm_network]       — the bug being guarded is back"
    fail=1
else
    refresh_resolved=1
fi

if [ "$refresh_ok" -eq 1 ]; then
    echo "[test_hpm_network] OK: hpm refresh succeeded against https://255.one/"
elif [ "$internet_alive" -eq 1 ]; then
    # Internet works but hpm refresh didn't succeed — that's a hpm /
    # TLS / cert chain issue worth flagging. It IS possible TLS fails
    # against a cert-chain hpm's tls stack doesn't yet handle.
    echo "[test_hpm_network] MISS: hpm refresh did not report success"
    echo "[test_hpm_network]       (DNS+TCP looked OK, suspect TLS / parse)"
    fail=1
else
    if [ "$refresh_resolved" -eq 1 ]; then
        echo "[test_hpm_network] SKIP: hpm refresh — no host internet"
    fi
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_hpm_network] FAIL (qemu rc=$rc)"
    echo "[test_hpm_network] --- full log (last 200 lines) ---"
    tail -n 200 "$LOG"
    exit 1
fi
echo "[test_hpm_network] PASS (qemu rc=$rc)"
