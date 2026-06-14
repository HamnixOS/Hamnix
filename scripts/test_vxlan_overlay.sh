#!/usr/bin/env bash
# scripts/test_vxlan_overlay.sh — native VXLAN-over-bridge wired path.
#
# Boots the kernel once with /etc/vxlan-overlay-test planted
# (ENABLE_VXLAN_OVERLAY_TEST=1). init/main.ad at boot:37.vxlan_overlay
# calls bridge_vxlan_overlay_selftest() (drivers/net/bridge.ad).
#
# Unlike scripts/test_vxlan.sh (which round-trips encap/decap inside
# vxlan.ad only) this test PROVES the cross-driver wiring: a bridge
# port's TX hook is bridge_vxlan_port_tx() which calls vxlan_encap();
# its output sits on an in-VM loopback ring; the loopback pump calls
# vxlan_decap() and re-injects the inner Ethernet frame at the
# peer-bridge port via bridge_rx(). The test asserts the inner frame
# captured at a WEST-side bridge port is byte-identical to what was
# originally injected on the EAST side.
#
# This is the option-5 in-VM loopback chosen over the two-QEMU-instance
# tap setup (per the task brief): one box, deterministic, host-
# independent, but proves the same wiring property. The remaining gap
# is routing the outer UDP/IPv4 datagram through virtio_net_tx /
# udp_rx port-4789 demux instead of a loopback buffer — the inner
# vxlan_encap byte stream is already RFC-7348-correct (proven by
# test_vxlan.sh's checksum-recompute assertions).
#
# Pass marker:  [bridge-vxlan] PASS
# Fail marker:  [bridge-vxlan] FAIL  /  [boot:37.vxlan_overlay] FAIL

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

export HAMNIX_BUILD_LOCK_TIMEOUT="${HAMNIX_BUILD_LOCK_TIMEOUT:-900}"

ELF=build/hamnix-kernel.elf

echo "[test_vxlan_overlay] (1/3) Build userland (init)"
bash scripts/build_user.sh >/dev/null

echo "[test_vxlan_overlay] (2/3) Build kernel with /etc/vxlan-overlay-test marker"
INIT_ELF=build/user/init.elf ENABLE_VXLAN_OVERLAY_TEST=1 \
    python3 scripts/build_initramfs.py >/dev/null
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1 || true' EXIT

echo "[test_vxlan_overlay] (3/3) Boot QEMU"
set +e
timeout 320s qemu-system-x86_64 \
    -kernel "$ELF" \
    -smp 1 \
    -nographic -no-reboot -m 256M -monitor none -serial stdio \
    > "$LOG" 2>&1 < /dev/null
rc=$?
set -e

echo "[test_vxlan_overlay] --- captured (bridge-vxlan lines) ---"
grep -E '\[bridge-vxlan\]|\[boot:37\.vxlan_overlay\]' "$LOG" || true
echo "[test_vxlan_overlay] --- end ---"

fail=0
if [ "$rc" -ne 0 ] && [ "$rc" -ne 124 ]; then
    echo "[test_vxlan_overlay] FAIL: qemu exited rc=$rc" >&2
    fail=1
fi

if grep -qF "[bridge-vxlan] FAIL" "$LOG"; then
    echo "[test_vxlan_overlay] FAIL: kernel self-test reported a wiring failure" >&2
    fail=1
fi
if grep -qF "[boot:37.vxlan_overlay] FAIL" "$LOG"; then
    echo "[test_vxlan_overlay] FAIL: boot gate reported FAIL" >&2
    fail=1
fi

check() {
    local label="$1" needle="$2"
    if grep -qF "$needle" "$LOG"; then
        echo "[test_vxlan_overlay] PASS: $label"
    else
        echo "[test_vxlan_overlay] FAIL: $label (expected '$needle')" >&2
        fail=1
    fi
}

check "self-test ran"               "[bridge-vxlan] overlay self-test start"
check "encap fired via bridge port" "[bridge-vxlan] PASS encap-fired-via-bridge-port"
check "outer on loopback ring"      "[bridge-vxlan] PASS outer-on-loopback-ring"
check "decap pumped into bridge"    "[bridge-vxlan] PASS decap-pumped-into-bridge"
check "west capture fired"          "[bridge-vxlan] PASS west-capture-fired"
check "east capture fired twice"    "[bridge-vxlan] PASS east-capture-fired-twice"
check "roundtrip byte-identical"    "[bridge-vxlan] PASS roundtrip-byte-identical (inner)"
check "overlay PASS banner"         "[bridge-vxlan] PASS"
check "boot gate PASS"              "[boot:37.vxlan_overlay] PASS"

if [ "$fail" -ne 0 ]; then
    echo "[test_vxlan_overlay] FAIL"
    exit 1
fi

echo "[test_vxlan_overlay] PASS — native VXLAN overlay wired through the learning bridge: bridge_rx -> bridge port TX hook -> vxlan_encap -> in-VM loopback -> vxlan_decap -> bridge_rx delivers the inner Ethernet frame byte-identical to a capture port on the far side"
