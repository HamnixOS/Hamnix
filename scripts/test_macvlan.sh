#!/usr/bin/env bash
# scripts/test_macvlan.sh — native macvlan (Linux drivers/net/macvlan.c)
# virtual-link self-test.
#
# Boots the kernel once with /etc/macvlan-test planted (ENABLE_MACVLAN_TEST=1).
# init/main.ad at boot:37.macvlan calls macvlan_selftest() (drivers/net/
# macvlan.ad), a fully in-memory test (NO external NIC required) that PROVES the
# core macvlan semantics:
#
#   * Multiple virtual interfaces over ONE parent netdev, each with its OWN
#     distinct MAC address (the defining macvlan property); a duplicate MAC is
#     rejected.
#   * RX demux: a frame received on the parent is steered to the macvlan whose
#     MAC == the frame's destination MAC (proved for two distinct macvlans);
#     a broadcast frame is flagged for per-mode flood; a frame for a MAC owned
#     by no macvlan is delivered to NONE (dropped).
#   * TX egress: a macvlan's outbound frame has its SOURCE MAC rewritten to the
#     macvlan's own MAC; a frame for an off-host destination egresses to the
#     parent (the wire).
#   * bridge mode: two macvlans on the same parent deliver to each other in-host
#     without leaving for the wire.
#   * private mode: a frame from one macvlan to a peer macvlan on the same
#     parent is ISOLATED (blocked), while a frame to an off-host MAC still
#     egresses to the wire.
#
# Boot path: a raw 64-bit Hamnix ELF will NOT boot under `qemu -kernel` on this
# host; the _kernel_iso.sh PATH shim (sourced by _build_lock.sh) transparently
# wraps the ELFCLASS64 kernel in a BIOS GRUB ISO, so the `-kernel "$ELF"`
# invocation below boots through the ISO shim.
#
# Pass marker:  [macvlan] PASS
# Fail marker:  [macvlan] FAIL / self-test reported FAIL

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

export HAMNIX_BUILD_LOCK_TIMEOUT="${HAMNIX_BUILD_LOCK_TIMEOUT:-900}"

ELF=build/hamnix-kernel.elf

echo "[test_macvlan] (1/3) Build userland (init)"
bash scripts/build_user.sh >/dev/null

echo "[test_macvlan] (2/3) Build kernel with /etc/macvlan-test marker"
INIT_ELF=build/user/init.elf ENABLE_MACVLAN_TEST=1 \
    python3 scripts/build_initramfs.py >/dev/null
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

LOG=$(mktemp)
# Restore the default initramfs afterwards + clean up the log.
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1 || true' EXIT

echo "[test_macvlan] (3/3) Boot QEMU"
set +e
timeout 320s qemu-system-x86_64 \
    -kernel "$ELF" \
    -smp 1 \
    -nographic -no-reboot -m 256M -monitor none -serial stdio \
    > "$LOG" 2>&1 < /dev/null
rc=$?
set -e

echo "[test_macvlan] --- captured (macvlan lines) ---"
grep -E '\[macvlan\]|\[boot:37.macvlan\]' "$LOG" || true
echo "[test_macvlan] --- end ---"

fail=0

if [ "$rc" -ne 0 ] && [ "$rc" -ne 124 ]; then
    echo "[test_macvlan] FAIL: qemu exited rc=$rc" >&2
    fail=1
fi

if grep -qF "[macvlan] FAIL" "$LOG"; then
    echo "[test_macvlan] FAIL: kernel self-test reported an internal failure" >&2
    fail=1
fi
if grep -qF "[boot:37.macvlan] FAIL" "$LOG"; then
    echo "[test_macvlan] FAIL: boot gate reported FAIL" >&2
    fail=1
fi

check() {
    local label="$1" needle="$2"
    if grep -qF "$needle" "$LOG"; then
        echo "[test_macvlan] PASS: $label"
    else
        echo "[test_macvlan] FAIL: $label (expected '$needle')" >&2
        fail=1
    fi
}

check "self-test ran"             "[macvlan] self-test start"
check "distinct MACs"             "[macvlan] PASS distinct-macs"
check "reject duplicate MAC"      "[macvlan] PASS reject-duplicate-mac"
check "rx demux to A"             "[macvlan] PASS rx-demux-to-A"
check "rx demux to B"             "[macvlan] PASS rx-demux-to-B"
check "unknown dst dropped"       "[macvlan] PASS rx-demux-unknown-dropped"
check "broadcast flood"           "[macvlan] PASS rx-demux-broadcast-flood"
check "egress src-mac rewrite"    "[macvlan] PASS tx-egress-srcmac-rewrite"
check "bridge peer-to-peer"       "[macvlan] PASS bridge-mode-peer-to-peer"
check "private peer isolated"     "[macvlan] PASS private-mode-peer-isolated"
check "private off-host wire"     "[macvlan] PASS private-mode-offhost-egresses-wire"
check "macvlan PASS banner"       "[macvlan] PASS"
check "boot gate PASS"            "[boot:37.macvlan] PASS"

if [ "$fail" -ne 0 ]; then
    echo "[test_macvlan] FAIL"
    exit 1
fi

echo "[test_macvlan] PASS — native macvlan: multiple virtual interfaces over one parent each with its own distinct MAC; RX demux steers a frame to the macvlan owning its destination MAC and drops a frame for an unknown MAC; egress rewrites the source MAC to the macvlan's own; bridge-mode peers on the same parent deliver to each other in-host; private-mode peer traffic is isolated while off-host traffic still egresses to the wire"
