#!/usr/bin/env bash
# scripts/test_geneve.sh — native GENEVE (RFC 8926) encap/decap self-test.
#
# Boots the kernel once with /etc/geneve-test planted (ENABLE_GENEVE_TEST=1).
# init/main.ad at boot:37.geneve calls geneve_selftest() (drivers/net/geneve.ad),
# a fully in-memory test (NO external NIC required) that PROVES the native
# GENEVE overlay path AND its distinguishing variable-length option TLVs:
#
#   * Builds a 2-entry GENEVE option block — a CRITICAL option (class 0x0101,
#     8 data bytes) plus a non-critical option (class 0x0202, 4 data bytes) —
#     and walks the TLVs by their 4-byte-word Length both before encap and on
#     the wire.
#   * ENCAP: a known inner Ethernet frame is tunneled to a VNI over UDP/IPv4
#     producing Eth | IP(proto=UDP) | UDP(dport=6081) | GENEVE-base(VNI) |
#     options | inner, with all lengths and checksums computed via the
#     existing native stack helpers (ip_csum16 + a pseudo-header UDP csum).
#   * DECAP: the outer frame is validated (UDP/6081 + version 0 + option block
#     fits) and the variable option block is STRIPPED to recover the inner
#     Ethernet frame BYTE-FOR-BYTE.
#   * The outer frame is asserted to carry dport 6081, version 0, the correct
#     Opt Len, the C (critical-options-present) flag, the TEB protocol type
#     0x6558, the correct 24-bit VNI, byte-identical option TLVs, and a
#     re-computed-and-matched IPv4 + UDP checksum — across two distinct VNIs
#     (100, 7777) each with its own option block.
#   * A non-6081 frame is rejected (negative test).
#
# Boot path: a raw 64-bit Hamnix ELF will NOT boot under `qemu -kernel` on
# this host; the _kernel_iso.sh PATH shim (sourced by _build_lock.sh)
# transparently wraps the ELFCLASS64 kernel in a BIOS GRUB ISO, so the
# `-kernel "$ELF"` invocation below boots through the ISO shim.
#
# Pass marker:  [geneve] PASS
# Fail marker:  [geneve] FAIL / self-test reported FAIL

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

export HAMNIX_BUILD_LOCK_TIMEOUT="${HAMNIX_BUILD_LOCK_TIMEOUT:-900}"

ELF=build/hamnix-kernel.elf

echo "[test_geneve] (1/3) Build userland (init)"
bash scripts/build_user.sh >/dev/null

echo "[test_geneve] (2/3) Build kernel with /etc/geneve-test marker"
INIT_ELF=build/user/init.elf ENABLE_GENEVE_TEST=1 \
    python3 scripts/build_initramfs.py >/dev/null
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

LOG=$(mktemp)
# Restore the default initramfs afterwards + clean up the log.
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1 || true' EXIT

echo "[test_geneve] (3/3) Boot QEMU"
set +e
timeout 320s qemu-system-x86_64 \
    -kernel "$ELF" \
    -smp 1 \
    -nographic -no-reboot -m 256M -monitor none -serial stdio \
    > "$LOG" 2>&1 < /dev/null
rc=$?
set -e

echo "[test_geneve] --- captured (geneve lines) ---"
grep -E '\[geneve\]|\[boot:37.geneve\]' "$LOG" || true
echo "[test_geneve] --- end ---"

fail=0

if [ "$rc" -ne 0 ] && [ "$rc" -ne 124 ]; then
    echo "[test_geneve] FAIL: qemu exited rc=$rc" >&2
    fail=1
fi

if grep -qF "[geneve] FAIL" "$LOG"; then
    echo "[test_geneve] FAIL: kernel self-test reported an internal failure" >&2
    fail=1
fi
if grep -qF "[boot:37.geneve] FAIL" "$LOG"; then
    echo "[test_geneve] FAIL: boot gate reported FAIL" >&2
    fail=1
fi

check() {
    local label="$1" needle="$2"
    if grep -qF "$needle" "$LOG"; then
        echo "[test_geneve] PASS: $label"
    else
        echo "[test_geneve] FAIL: $label (expected '$needle')" >&2
        fail=1
    fi
}

check "self-test ran"                "[geneve] self-test start"
check "opt build"                    "[geneve] PASS opt-build opts_len="
check "opt walk"                     "[geneve] PASS opt-walk"
check "outer length (VNI100)"        "[geneve] PASS outer-len="
check "dport 6081"                   "[geneve] PASS dport=6081"
check "version 0"                    "[geneve] PASS version=0"
check "optlen words"                 "[geneve] PASS optlen="
check "c-flag set"                   "[geneve] PASS c-flag-set"
check "proto-type TEB"               "[geneve] PASS proto-type=TEB(0x6558)"
check "vni 100"                      "[geneve] PASS vni=100"
check "ip checksum valid"            "[geneve] PASS ip-checksum-valid"
check "ip checksum self-consistent"  "[geneve] PASS ip-checksum-self-consistent"
check "udp checksum valid (VNI100)"  "[geneve] PASS udp-checksum-valid"
check "options byte-identical 100"   "[geneve] PASS options-byte-identical (VNI100)"
check "on-wire tlv reparse"          "[geneve] PASS on-wire-tlv-reparse (2 TLVs)"
check "roundtrip byte-identical 100" "[geneve] PASS roundtrip-byte-identical (VNI100)"
check "vni 7777"                     "[geneve] PASS vni=7777"
check "udp checksum valid (VNI7777)" "[geneve] PASS udp-checksum-valid (VNI7777)"
check "options byte-identical 7777"  "[geneve] PASS options-byte-identical (VNI7777)"
check "roundtrip byte-identical 7777" "[geneve] PASS roundtrip-byte-identical (VNI7777)"
check "reject non-geneve"            "[geneve] PASS reject-non-geneve (dport 1234)"
check "geneve PASS banner"           "[geneve] PASS"
check "boot gate PASS"               "[boot:37.geneve] PASS"

if [ "$fail" -ne 0 ]; then
    echo "[test_geneve] FAIL"
    exit 1
fi

echo "[test_geneve] PASS — native GENEVE (RFC 8926) overlay: inner-frame ENCAP into Eth|IP|UDP:6081|GENEVE|options|inner with real option-TLV build/parse (critical + non-critical TLVs walked by 4-byte-word length), correct lengths + IPv4/UDP checksums, byte-exact DECAP round-trip past the variable option block, 24-bit VNI + option carriage across two VNIs all verified"
