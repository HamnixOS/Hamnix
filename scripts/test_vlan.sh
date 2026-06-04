#!/usr/bin/env bash
# scripts/test_vlan.sh — native IEEE 802.1Q VLAN tagging self-test.
#
# Boots the kernel once with /etc/vlan-test planted (ENABLE_VLAN_TEST=1).
# init/main.ad at boot:37.vlan calls vlan_selftest() (drivers/net/vlan.ad),
# a fully in-memory test (NO external NIC required) that PROVES the native
# 802.1Q VLAN path:
#
#   * INSERT: a 4-byte tag (TPID 0x8100 + TCI = PCP|DEI|VID) is spliced into
#     an untagged Ethernet frame right after the 12-byte src/dst MAC pair,
#     shifting the original ethertype+payload right; the tag bytes and the
#     decoded {PCP,DEI,VID} are verified, and the inner frame preserved.
#   * STRIP: the tag is removed, the original untagged frame recovered
#     BYTE-FOR-BYTE, and {PCP,DEI,VID} decoded back. Done for two distinct
#     {PCP,DEI,VID} tuples (incl. all-fields-hot VID 4094, PCP 7, DEI 1).
#   * INGRESS FILTERING: a tagged frame whose VID is registered in the
#     per-VLAN interface table is accepted (inner frame delivered); an
#     unregistered VID is DROPPED (and the rx-drop counter bumped).
#   * EGRESS: a frame leaving a logical vlan interface (eth0.200) is tagged
#     with that interface's VID (200) and default PCP.
#
# Boot path: a raw 64-bit Hamnix ELF will NOT boot under `qemu -kernel` on
# this host; the _kernel_iso.sh PATH shim (sourced by _build_lock.sh)
# transparently wraps the ELFCLASS64 kernel in a BIOS GRUB ISO, so the
# `-kernel "$ELF"` invocation below boots through the ISO shim.
#
# Pass marker:  [vlan] PASS
# Fail marker:  [vlan] FAIL / self-test reported FAIL

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

export HAMNIX_BUILD_LOCK_TIMEOUT="${HAMNIX_BUILD_LOCK_TIMEOUT:-900}"

ELF=build/hamnix-kernel.elf

echo "[test_vlan] (1/3) Build userland (init)"
bash scripts/build_user.sh >/dev/null

echo "[test_vlan] (2/3) Build kernel with /etc/vlan-test marker"
INIT_ELF=build/user/init.elf ENABLE_VLAN_TEST=1 \
    python3 scripts/build_initramfs.py >/dev/null
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

LOG=$(mktemp)
# Restore the default initramfs afterwards + clean up the log.
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1 || true' EXIT

echo "[test_vlan] (3/3) Boot QEMU"
set +e
timeout 320s qemu-system-x86_64 \
    -kernel "$ELF" \
    -smp 1 \
    -nographic -no-reboot -m 256M -monitor none -serial stdio \
    > "$LOG" 2>&1 < /dev/null
rc=$?
set -e

echo "[test_vlan] --- captured (vlan lines) ---"
grep -E '\[vlan\]|\[boot:37.vlan\]' "$LOG" || true
echo "[test_vlan] --- end ---"

fail=0

if [ "$rc" -ne 0 ] && [ "$rc" -ne 124 ]; then
    echo "[test_vlan] FAIL: qemu exited rc=$rc" >&2
    fail=1
fi

if grep -qF "[vlan] FAIL" "$LOG"; then
    echo "[test_vlan] FAIL: kernel self-test reported an internal failure" >&2
    fail=1
fi
if grep -qF "[boot:37.vlan] FAIL" "$LOG"; then
    echo "[test_vlan] FAIL: boot gate reported FAIL" >&2
    fail=1
fi

check() {
    local label="$1" needle="$2"
    if grep -qF "$needle" "$LOG"; then
        echo "[test_vlan] PASS: $label"
    else
        echo "[test_vlan] FAIL: $label (expected '$needle')" >&2
        fail=1
    fi
}

check "self-test ran"               "[vlan] self-test start"
check "interface add"               "[vlan] PASS if-add"
check "interface lookup"            "[vlan] PASS if-lookup"
check "tag insert + fields"         "[vlan] tag insert + fields OK"
check "tag strip round-trip"        "[vlan] tag strip round-trip byte-identical OK"
check "roundtrip vid100"            "[vlan] PASS roundtrip-vid100"
check "roundtrip vid4094"           "[vlan] PASS roundtrip-vid4094"
check "ingress accept"              "[vlan] ingress-filter accept (VID 100) OK"
check "ingress drop"                "[vlan] ingress-filter drop (VID 300) OK"
check "egress tagging"              "[vlan] egress tagging (eth0.200 -> VID 200) OK"
check "vlan PASS banner"            "[vlan] PASS"
check "boot gate PASS"              "[boot:37.vlan] PASS"

if [ "$fail" -ne 0 ]; then
    echo "[test_vlan] FAIL"
    exit 1
fi

echo "[test_vlan] PASS — native IEEE 802.1Q VLAN tagging: 4-byte tag (TPID 0x8100 + TCI PCP|DEI|VID) INSERT spliced after the MAC pair with the inner ethertype/payload shifted right, byte-exact STRIP round-trip decoding {PCP,DEI,VID}, per-VLAN interface table backing ingress filtering (registered VID accepted + inner delivered, unregistered VID dropped) and egress tagging (eth0.200 -> VID 200) all verified"
