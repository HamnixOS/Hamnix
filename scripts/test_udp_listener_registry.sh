#!/usr/bin/env bash
# scripts/test_udp_listener_registry.sh — generic UDP kernel-listener
# registry exercise.
#
# Boots the kernel once with /etc/udp-listener-test planted
# (ENABLE_UDP_LISTENER_TEST=1). init/main.ad at boot:37.udp_listener
# calls udp_listener_selftest() (drivers/net/udp.ad). The selftest
# directly drives the registry primitives:
#
#   - udp_register_listener installs a synthetic listener on port 33333
#     with a peer_data tag.
#   - udp_local_inject feeds a 32-byte deterministic payload through
#     the real udp_rx pipeline; the listener latches what it received.
#   - asserts (peer, src_ip, src_port, payload, byte0, byte_last) round-trip.
#   - udp_unregister_listener removes the entry; a second inject must
#     NOT fire the listener.
#   - re-register on the original port AND a second port to prove
#     multiple ports route independently.
#
# This is the unit gate for the registry that VXLAN (port 4789) and
# WireGuard (port 51820) both consume — the wired-data-path tests
# (test_vxlan_overlay.sh, test_wireguard_overlay.sh) are end-to-end
# but this one isolates the registry semantics.
#
# Pass marker:  [udp-listener] PASS
# Fail marker:  [udp-listener] FAIL  /  [boot:37.udp_listener] FAIL

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

export HAMNIX_BUILD_LOCK_TIMEOUT="${HAMNIX_BUILD_LOCK_TIMEOUT:-900}"

ELF=build/hamnix-kernel.elf

echo "[test_udp_listener_registry] (1/3) Build userland (init)"
bash scripts/build_user.sh >/dev/null

echo "[test_udp_listener_registry] (2/3) Build kernel with /etc/udp-listener-test marker"
INIT_ELF=build/user/init.elf ENABLE_UDP_LISTENER_TEST=1 \
    python3 scripts/build_initramfs.py >/dev/null
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1 || true' EXIT

echo "[test_udp_listener_registry] (3/3) Boot QEMU"
set +e
timeout 320s qemu-system-x86_64 \
    -kernel "$ELF" \
    -smp 1 \
    -nographic -no-reboot -m 256M -monitor none -serial stdio \
    > "$LOG" 2>&1 < /dev/null
rc=$?
set -e

echo "[test_udp_listener_registry] --- captured (udp-listener lines) ---"
grep -E '\[udp-listener\]|\[boot:37\.udp_listener\]' "$LOG" || true
echo "[test_udp_listener_registry] --- end ---"

fail=0
if [ "$rc" -ne 0 ] && [ "$rc" -ne 124 ]; then
    echo "[test_udp_listener_registry] FAIL: qemu exited rc=$rc" >&2
    fail=1
fi

if grep -qF "[udp-listener] FAIL" "$LOG"; then
    echo "[test_udp_listener_registry] FAIL: kernel self-test reported a registry failure" >&2
    fail=1
fi
if grep -qF "[boot:37.udp_listener] FAIL" "$LOG"; then
    echo "[test_udp_listener_registry] FAIL: boot gate reported FAIL" >&2
    fail=1
fi

check() {
    local label="$1" needle="$2"
    if grep -qF "$needle" "$LOG"; then
        echo "[test_udp_listener_registry] PASS: $label"
    else
        echo "[test_udp_listener_registry] FAIL: $label (expected '$needle')" >&2
        fail=1
    fi
}

check "self-test ran"               "[udp-listener] self-test start"
check "register"                    "[udp-listener] PASS register"
check "dispatch fired once"         "[udp-listener] PASS dispatch-fired-once"
check "peer-data round-trip"        "[udp-listener] PASS peer-data-roundtrip"
check "src-ip round-trip"           "[udp-listener] PASS src-ip-roundtrip"
check "src-port round-trip"         "[udp-listener] PASS src-port-roundtrip"
check "payload-length round-trip"   "[udp-listener] PASS payload-length-roundtrip"
check "payload-bytes round-trip"    "[udp-listener] PASS payload-bytes-roundtrip"
check "unregister"                  "[udp-listener] PASS unregister"
check "no dispatch after unregister" "[udp-listener] PASS no-dispatch-after-unregister"
check "multi-port routing"          "[udp-listener] PASS multi-port-routing"
check "overall PASS banner"         "[udp-listener] PASS"
check "boot gate PASS"              "[boot:37.udp_listener] PASS"

if [ "$fail" -ne 0 ]; then
    echo "[test_udp_listener_registry] FAIL"
    exit 1
fi

echo "[test_udp_listener_registry] PASS — generic UDP kernel-listener registry (udp_register_listener / udp_local_inject / udp_rx tail dispatch / udp_unregister_listener) works end-to-end with a synthetic listener; this is the same registry that drives the VXLAN port-4789 and WireGuard port-51820 wired data paths"
