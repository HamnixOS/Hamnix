#!/usr/bin/env bash
# scripts/test_gre.sh — native GRE (RFC 2784) encap/decap self-test.
#
# Boots the kernel once with /etc/gre-test planted (ENABLE_GRE_TEST=1).
# init/main.ad at boot:37.gre calls gre_selftest() (drivers/net/gre.ad),
# a fully in-memory test (NO external NIC required) that PROVES the native
# GRE tunnel path:
#
#   * ENCAP: a known inner IPv4 packet is tunneled to a remote endpoint
#     producing OuterIP(proto=47) | GRE | inner, with the outer IPv4 header
#     checksum computed via the existing native ip_csum16 helper, and an
#     optional RFC 2784 §2.5 GRE checksum over the GRE header + payload.
#   * DECAP: the outer frame is validated (IPv4 / proto 47 / version-0 GRE)
#     and the inner IPv4 packet is recovered BYTE-FOR-BYTE; the GRE
#     Protocol Type is parsed back as 0x0800.
#   * Done BOTH with the GRE checksum disabled (4-byte header) and enabled
#     (8-byte header, C bit), with the outer proto 47, a valid outer IPv4
#     checksum, and the correct GRE flags+protocol-type all asserted.
#   * A corrupted GRE-checksum frame is rejected (negative test).
#   * A small (local,remote,key) tunnel table resolves the send-by-key path.
#
# Boot path: a raw 64-bit Hamnix ELF will NOT boot under `qemu -kernel` on
# this host; the _kernel_iso.sh PATH shim (sourced by _build_lock.sh)
# transparently wraps the ELFCLASS64 kernel in a BIOS GRUB ISO, so the
# `-kernel "$ELF"` invocation below boots through the ISO shim.
#
# Pass marker:  [gre] PASS
# Fail marker:  [gre] FAIL / self-test reported FAIL

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

export HAMNIX_BUILD_LOCK_TIMEOUT="${HAMNIX_BUILD_LOCK_TIMEOUT:-900}"

ELF=build/hamnix-kernel.elf

echo "[test_gre] (1/3) Build userland (init)"
bash scripts/build_user.sh >/dev/null

echo "[test_gre] (2/3) Build kernel with /etc/gre-test marker"
INIT_ELF=build/user/init.elf ENABLE_GRE_TEST=1 \
    python3 scripts/build_initramfs.py >/dev/null
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

LOG=$(mktemp)
# Restore the default initramfs afterwards + clean up the log.
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1 || true' EXIT

echo "[test_gre] (3/3) Boot QEMU"
set +e
timeout 320s qemu-system-x86_64 \
    -kernel "$ELF" \
    -smp 1 \
    -nographic -no-reboot -m 256M -monitor none -serial stdio \
    > "$LOG" 2>&1 < /dev/null
rc=$?
set -e

echo "[test_gre] --- captured (gre lines) ---"
grep -E '\[gre\]|\[boot:37.gre\]' "$LOG" || true
echo "[test_gre] --- end ---"

fail=0

if [ "$rc" -ne 0 ] && [ "$rc" -ne 124 ]; then
    echo "[test_gre] FAIL: qemu exited rc=$rc" >&2
    fail=1
fi

if grep -qF "[gre] FAIL" "$LOG"; then
    echo "[test_gre] FAIL: kernel self-test reported an internal failure" >&2
    fail=1
fi
if grep -qF "[boot:37.gre] FAIL" "$LOG"; then
    echo "[test_gre] FAIL: boot gate reported FAIL" >&2
    fail=1
fi

check() {
    local label="$1" needle="$2"
    if grep -qF "$needle" "$LOG"; then
        echo "[test_gre] PASS: $label"
    else
        echo "[test_gre] FAIL: $label (expected '$needle')" >&2
        fail=1
    fi
}

check "self-test ran"               "[gre] self-test start"
check "tunnel add"                  "[gre] PASS tunnel-add"
check "tunnel lookup"               "[gre] PASS tunnel-lookup"
check "encap header valid"          "[gre] encap header valid OK"
check "decap round-trip identical"  "[gre] decap round-trip byte-identical OK"
check "roundtrip no-csum"           "[gre] PASS roundtrip-no-csum"
check "roundtrip csum"              "[gre] PASS roundtrip-csum"
check "checksum reject-corrupt"     "[gre] checksum reject-corrupt OK"
check "gre PASS banner"             "[gre] PASS"
check "boot gate PASS"              "[boot:37.gre] PASS"

if [ "$fail" -ne 0 ]; then
    echo "[test_gre] FAIL"
    exit 1
fi

echo "[test_gre] PASS — native GRE (RFC 2784) tunnel: inner IPv4 ENCAP into OuterIP(proto=47)|GRE|inner with correct lengths + IPv4 checksum, byte-exact DECAP round-trip carrying protocol-type 0x0800, both with and without the optional GRE checksum, corrupt-checksum rejection, and (local,remote,key) tunnel-table send-by-key all verified"
