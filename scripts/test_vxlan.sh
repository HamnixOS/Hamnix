#!/usr/bin/env bash
# scripts/test_vxlan.sh — native VXLAN (RFC 7348) encap/decap self-test.
#
# Boots the kernel once with /etc/vxlan-test planted (ENABLE_VXLAN_TEST=1).
# init/main.ad at boot:37.vxlan calls vxlan_selftest() (drivers/net/vxlan.ad),
# a fully in-memory test (NO external NIC required) that PROVES the native
# VXLAN overlay path:
#
#   * ENCAP: a known inner Ethernet frame is tunneled to a VNI over UDP/IPv4
#     producing Eth | IP(proto=UDP) | UDP(dport=4789) | VXLAN(VNI) | inner,
#     with all lengths and checksums computed via the existing native stack
#     helpers (ip_csum16 for the IPv4 header checksum, a pseudo-header UDP
#     checksum).
#   * DECAP: the outer frame is validated (UDP/4789 + VXLAN I-bit) and the
#     inner Ethernet frame is recovered BYTE-FOR-BYTE.
#   * The outer frame is asserted to carry dport 4789, the I-bit set, the
#     correct 24-bit VNI, and a re-computed-and-matched IPv4 + UDP checksum.
#   * Two distinct VNIs (100, 5000) are routed through a VNI->remote-VTEP
#     forwarding map, proving send-by-VNI lands on the right VTEP.
#   * A non-4789 frame is rejected (negative test).
#
# Boot path: a raw 64-bit Hamnix ELF will NOT boot under `qemu -kernel` on
# this host; the _kernel_iso.sh PATH shim (sourced by _build_lock.sh)
# transparently wraps the ELFCLASS64 kernel in a BIOS GRUB ISO, so the
# `-kernel "$ELF"` invocation below boots through the ISO shim.
#
# Pass marker:  [vxlan] PASS
# Fail marker:  [vxlan] FAIL / self-test reported FAIL

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

export HAMNIX_BUILD_LOCK_TIMEOUT="${HAMNIX_BUILD_LOCK_TIMEOUT:-900}"

ELF=build/hamnix-kernel.elf

echo "[test_vxlan] (1/3) Build userland (init)"
bash scripts/build_user.sh >/dev/null

echo "[test_vxlan] (2/3) Build kernel with /etc/vxlan-test marker"
INIT_ELF=build/user/init.elf ENABLE_VXLAN_TEST=1 \
    python3 scripts/build_initramfs.py >/dev/null
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

LOG=$(mktemp)
# Restore the default initramfs afterwards + clean up the log.
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1 || true' EXIT

echo "[test_vxlan] (3/3) Boot QEMU"
set +e
timeout 320s qemu-system-x86_64 \
    -kernel "$ELF" \
    -smp 1 \
    -nographic -no-reboot -m 256M -monitor none -serial stdio \
    > "$LOG" 2>&1 < /dev/null
rc=$?
set -e

echo "[test_vxlan] --- captured (vxlan lines) ---"
grep -E '\[vxlan\]|\[boot:37.vxlan\]' "$LOG" || true
echo "[test_vxlan] --- end ---"

fail=0

if [ "$rc" -ne 0 ] && [ "$rc" -ne 124 ]; then
    echo "[test_vxlan] FAIL: qemu exited rc=$rc" >&2
    fail=1
fi

if grep -qF "[vxlan] FAIL" "$LOG"; then
    echo "[test_vxlan] FAIL: kernel self-test reported an internal failure" >&2
    fail=1
fi
if grep -qF "[boot:37.vxlan] FAIL" "$LOG"; then
    echo "[test_vxlan] FAIL: boot gate reported FAIL" >&2
    fail=1
fi

check() {
    local label="$1" needle="$2"
    if grep -qF "$needle" "$LOG"; then
        echo "[test_vxlan] PASS: $label"
    else
        echo "[test_vxlan] FAIL: $label (expected '$needle')" >&2
        fail=1
    fi
}

check "self-test ran"               "[vxlan] self-test start"
check "fdb add"                     "[vxlan] PASS fdb-add"
check "outer length (VNI100)"       "[vxlan] PASS outer-len="
check "fdb route mac (VNI100)"      "[vxlan] PASS fdb-route-mac (VNI100 -> VTEP A)"
check "fdb route ip (VNI100)"       "[vxlan] PASS fdb-route-ip (VNI100 -> 10.0.0.2)"
check "dport 4789"                  "[vxlan] PASS dport=4789"
check "I-bit set"                   "[vxlan] PASS i-bit-set"
check "vni 100"                     "[vxlan] PASS vni=100"
check "ip checksum valid"           "[vxlan] PASS ip-checksum-valid"
check "ip checksum self-consistent" "[vxlan] PASS ip-checksum-self-consistent"
check "udp checksum valid (VNI100)" "[vxlan] PASS udp-checksum-valid"
check "roundtrip byte-identical 100" "[vxlan] PASS roundtrip-byte-identical (VNI100)"
check "fdb route (VNI5000)"         "[vxlan] PASS fdb-route (VNI5000 -> VTEP B 10.0.0.3)"
check "vni 5000"                    "[vxlan] PASS vni=5000"
check "udp checksum valid (VNI5000)" "[vxlan] PASS udp-checksum-valid (VNI5000)"
check "roundtrip byte-identical 5000" "[vxlan] PASS roundtrip-byte-identical (VNI5000)"
check "reject non-vxlan"            "[vxlan] PASS reject-non-vxlan (dport 1234)"
check "vxlan PASS banner"           "[vxlan] PASS"
check "boot gate PASS"              "[boot:37.vxlan] PASS"

if [ "$fail" -ne 0 ]; then
    echo "[test_vxlan] FAIL"
    exit 1
fi

echo "[test_vxlan] PASS — native VXLAN (RFC 7348) overlay: inner-frame ENCAP into Eth|IP|UDP:4789|VXLAN|inner with correct lengths + IPv4/UDP checksums, byte-exact DECAP round-trip, 24-bit VNI carriage, and VNI->VTEP forwarding-map routing across two VNIs all verified"
