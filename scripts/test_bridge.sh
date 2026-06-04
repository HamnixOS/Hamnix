#!/usr/bin/env bash
# scripts/test_bridge.sh — native learning Ethernet bridge self-test.
#
# Boots the kernel once with /etc/bridge-test planted (ENABLE_BRIDGE_TEST=1).
# init/main.ad at boot:37.bridge calls bridge_selftest() (drivers/net/bridge.ad),
# a fully in-memory test (NO external NIC required) that PROVES the native
# learning-bridge (brX/brctl-equivalent) forwarding path:
#
#   * Three fake capture ports are joined into one bridge; each port's TX
#     hook records the frames the bridge pushes out of it.
#   * UNKNOWN-UNICAST FLOOD: a frame from port0 (src=AA, dst=BB unknown)
#     floods to port1 + port2 but NOT back out port0 (the ingress port).
#   * MAC LEARNING: the source AA is learned on port0; BB on port1; CC on
#     port2 — the FDB lookup returns the right ingress port for each.
#   * LEARNED UNICAST: once AA is learned, a frame dst=AA is delivered ONLY
#     to port0 (unicast — not flooded, not echoed to the ingress port) and
#     the delivered bytes are byte-identical to the sent frame.
#   * BROADCAST FLOOD: a frame dst=FF:FF:FF:FF:FF:FF floods to all
#     non-ingress ports, and the broadcast MAC is never learned into the FDB.
#
# Boot path: a raw 64-bit Hamnix ELF will NOT boot under `qemu -kernel` on
# this host; the _kernel_iso.sh PATH shim (sourced by _build_lock.sh)
# transparently wraps the ELFCLASS64 kernel in a BIOS GRUB ISO, so the
# `-kernel "$ELF"` invocation below boots through the ISO shim.
#
# Pass marker:  [bridge] PASS
# Fail marker:  [bridge] FAIL / self-test reported FAIL

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

export HAMNIX_BUILD_LOCK_TIMEOUT="${HAMNIX_BUILD_LOCK_TIMEOUT:-900}"

ELF=build/hamnix-kernel.elf

echo "[test_bridge] (1/3) Build userland (init)"
bash scripts/build_user.sh >/dev/null

echo "[test_bridge] (2/3) Build kernel with /etc/bridge-test marker"
INIT_ELF=build/user/init.elf ENABLE_BRIDGE_TEST=1 \
    python3 scripts/build_initramfs.py >/dev/null
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

LOG=$(mktemp)
# Restore the default initramfs afterwards + clean up the log.
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1 || true' EXIT

echo "[test_bridge] (3/3) Boot QEMU"
set +e
timeout 320s qemu-system-x86_64 \
    -kernel "$ELF" \
    -smp 1 \
    -nographic -no-reboot -m 256M -monitor none -serial stdio \
    > "$LOG" 2>&1 < /dev/null
rc=$?
set -e

echo "[test_bridge] --- captured (bridge lines) ---"
grep -E '\[bridge\]|\[boot:37.bridge\]' "$LOG" || true
echo "[test_bridge] --- end ---"

fail=0

if [ "$rc" -ne 0 ] && [ "$rc" -ne 124 ]; then
    echo "[test_bridge] FAIL: qemu exited rc=$rc" >&2
    fail=1
fi

if grep -qF "[bridge] FAIL" "$LOG"; then
    echo "[test_bridge] FAIL: kernel self-test reported an internal failure" >&2
    fail=1
fi
if grep -qF "[boot:37.bridge] FAIL" "$LOG"; then
    echo "[test_bridge] FAIL: boot gate reported FAIL" >&2
    fail=1
fi

check() {
    local label="$1" needle="$2"
    if grep -qF "$needle" "$LOG"; then
        echo "[test_bridge] PASS: $label"
    else
        echo "[test_bridge] FAIL: $label (expected '$needle')" >&2
        fail=1
    fi
}

check "self-test ran"        "[bridge] self-test start"
check "ports joined"         "[bridge] ports OK (3 ports joined)"
check "flood unknown"        "[bridge] flood-unknown OK"
check "fdb learned AA"       "[bridge] fdb-learned AA->port0 OK"
check "learned unicast"      "[bridge] learned-unicast OK"
check "fdb learned BB"       "[bridge] fdb-learned BB->port1 OK"
check "broadcast flood"      "[bridge] broadcast-flood OK"
check "fdb verified"         "[bridge] fdb-verified OK (AA/BB/CC learned, FF not)"
check "bridge PASS banner"   "[bridge] PASS"
check "boot gate PASS"       "[boot:37.bridge] PASS"

if [ "$fail" -ne 0 ]; then
    echo "[test_bridge] FAIL"
    exit 1
fi

echo "[test_bridge] PASS — native learning Ethernet bridge: MAC-learning FDB, unknown-unicast/broadcast FLOOD to all non-ingress ports, learned-unicast forwarded ONLY to the learned port (never hairpinned), byte-exact frame delivery all verified"
