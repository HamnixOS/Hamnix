#!/usr/bin/env bash
# scripts/test_ipip.sh — native IPv4-in-IPv4 tunnel (RFC 2003, "ipip")
# encap/decap self-test.
#
# Boots the kernel once with /etc/ipip-test planted (ENABLE_IPIP_TEST=1).
# init/main.ad at boot:37.ipip calls ipip_selftest() (drivers/net/ipip.ad), a
# fully in-memory test (NO external NIC required) that PROVES IPv4-in-IPv4
# encapsulation per RFC 2003:
#
#   * ENCAP prepends an OUTER IPv4 header (protocol 4 = IPIP) to a complete
#     inner IPv4 packet, with the correct outer Total Length and a valid outer
#     IPv4 header checksum (reusing the native ip_csum16); the inner packet is
#     carried verbatim (its TTL is NOT decremented, per RFC 2003 §3.1).
#   * DECAP validates proto==4 and outer dst == our endpoint, strips the outer
#     header, and recovers the inner IPv4 packet BYTE-IDENTICALLY.
#   * Rejections: a frame whose outer protocol isn't 4 is dropped (-1); a frame
#     whose outer destination isn't our endpoint is dropped (-5).
#
# Boot path: a raw 64-bit Hamnix ELF will NOT boot under `qemu -kernel` on this
# host; the _kernel_iso.sh PATH shim (sourced by _build_lock.sh) transparently
# wraps the ELFCLASS64 kernel in a BIOS GRUB ISO, so the `-kernel "$ELF"`
# invocation below boots through the ISO shim.
#
# Pass marker:  [ipip] PASS
# Fail marker:  [ipip] FAIL / self-test reported FAIL

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

export HAMNIX_BUILD_LOCK_TIMEOUT="${HAMNIX_BUILD_LOCK_TIMEOUT:-900}"

ELF=build/hamnix-kernel.elf

echo "[test_ipip] (1/3) Build userland (init)"
bash scripts/build_user.sh >/dev/null

echo "[test_ipip] (2/3) Build kernel with /etc/ipip-test marker"
INIT_ELF=build/user/init.elf ENABLE_IPIP_TEST=1 \
    python3 scripts/build_initramfs.py >/dev/null
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

LOG=$(mktemp)
# Restore the default initramfs afterwards + clean up the log.
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1 || true' EXIT

echo "[test_ipip] (3/3) Boot QEMU"
set +e
timeout 320s qemu-system-x86_64 \
    -kernel "$ELF" \
    -smp 1 \
    -nographic -no-reboot -m 256M -monitor none -serial stdio \
    > "$LOG" 2>&1 < /dev/null
rc=$?
set -e

echo "[test_ipip] --- captured (ipip lines) ---"
grep -E '\[ipip\]|\[boot:37.ipip\]' "$LOG" || true
echo "[test_ipip] --- end ---"

fail=0

if [ "$rc" -ne 0 ] && [ "$rc" -ne 124 ]; then
    echo "[test_ipip] FAIL: qemu exited rc=$rc" >&2
    fail=1
fi

if grep -qF "[ipip] FAIL" "$LOG"; then
    echo "[test_ipip] FAIL: kernel self-test reported an internal failure" >&2
    fail=1
fi
if grep -qF "[boot:37.ipip] FAIL" "$LOG"; then
    echo "[test_ipip] FAIL: boot gate reported FAIL" >&2
    fail=1
fi

check() {
    local label="$1" needle="$2"
    if grep -qF "$needle" "$LOG"; then
        echo "[test_ipip] PASS: $label"
    else
        echo "[test_ipip] FAIL: $label (expected '$needle')" >&2
        fail=1
    fi
}

check "self-test ran"             "[ipip] self-test start"
check "tunnel add"                "[ipip] PASS tunnel-add"
check "tunnel lookup"             "[ipip] PASS tunnel-lookup"
check "roundtrip byte-identical"  "[ipip] PASS roundtrip-byte-identical"
check "reject wrong proto"        "[ipip] PASS reject-wrong-proto"
check "reject wrong dst"          "[ipip] PASS reject-wrong-dst"
check "ipip PASS banner"          "[ipip] PASS"
check "boot gate PASS"            "[boot:37.ipip] PASS"

if [ "$fail" -ne 0 ]; then
    echo "[test_ipip] FAIL"
    exit 1
fi

echo "[test_ipip] PASS — native IPv4-in-IPv4 (RFC 2003): ENCAP prepends an outer IPv4 header (protocol 4) to a complete inner IPv4 packet with the correct outer Total Length and a valid outer IPv4 header checksum and carries the inner packet verbatim; DECAP validates proto==4 + outer dst==endpoint, strips the outer header and recovers the inner IPv4 packet byte-identically; a wrong-protocol outer frame and a wrong-destination outer frame are both rejected"
