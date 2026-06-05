#!/usr/bin/env bash
# scripts/test_sit.sh — native 6in4 / sit tunnel (RFC 4213, IPv6-in-IPv4)
# encap/decap self-test.
#
# Boots the kernel once with /etc/sit-test planted (ENABLE_SIT_TEST=1).
# init/main.ad at boot:37.sit calls sit_selftest() (drivers/net/sit.ad), a
# fully in-memory test (NO external NIC required) that PROVES IPv6-in-IPv4
# encapsulation per RFC 4213 §3:
#
#   * ENCAP prepends an OUTER IPv4 header (protocol 41 = IPv6 encapsulation) to
#     a complete inner IPv6 packet, with the correct outer Total Length and a
#     valid outer IPv4 header checksum (reusing the native ip_csum16); the
#     inner IPv6 packet is carried verbatim.
#   * The RFC 3056 6to4 prefix derivation (2002:V4ADDR::/48) is checked for a
#     known public IPv4 address.
#   * DECAP validates proto==41 and outer dst == our endpoint, strips the outer
#     header, and recovers the inner IPv6 packet BYTE-IDENTICALLY.
#   * Rejections: a frame whose outer protocol isn't 41 is dropped (-1); a
#     frame whose outer destination isn't our endpoint is dropped (-5).
#
# Boot path: a raw 64-bit Hamnix ELF will NOT boot under `qemu -kernel` on this
# host; the _kernel_iso.sh PATH shim (sourced by _build_lock.sh) transparently
# wraps the ELFCLASS64 kernel in a BIOS GRUB ISO, so the `-kernel "$ELF"`
# invocation below boots through the ISO shim.
#
# Pass marker:  [sit] PASS
# Fail marker:  [sit] FAIL / self-test reported FAIL

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

export HAMNIX_BUILD_LOCK_TIMEOUT="${HAMNIX_BUILD_LOCK_TIMEOUT:-900}"

ELF=build/hamnix-kernel.elf

echo "[test_sit] (1/3) Build userland (init)"
bash scripts/build_user.sh >/dev/null

echo "[test_sit] (2/3) Build kernel with /etc/sit-test marker"
INIT_ELF=build/user/init.elf ENABLE_SIT_TEST=1 \
    python3 scripts/build_initramfs.py >/dev/null
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

LOG=$(mktemp)
# Restore the default initramfs afterwards + clean up the log.
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1 || true' EXIT

echo "[test_sit] (3/3) Boot QEMU"
set +e
timeout 320s qemu-system-x86_64 \
    -kernel "$ELF" \
    -smp 1 \
    -nographic -no-reboot -m 256M -monitor none -serial stdio \
    > "$LOG" 2>&1 < /dev/null
rc=$?
set -e

echo "[test_sit] --- captured (sit lines) ---"
grep -E '\[sit\]|\[boot:37.sit\]' "$LOG" || true
echo "[test_sit] --- end ---"

fail=0

if [ "$rc" -ne 0 ] && [ "$rc" -ne 124 ]; then
    echo "[test_sit] FAIL: qemu exited rc=$rc" >&2
    fail=1
fi

if grep -qF "[sit] FAIL" "$LOG"; then
    echo "[test_sit] FAIL: kernel self-test reported an internal failure" >&2
    fail=1
fi
if grep -qF "[boot:37.sit] FAIL" "$LOG"; then
    echo "[test_sit] FAIL: boot gate reported FAIL" >&2
    fail=1
fi

check() {
    local label="$1" needle="$2"
    if grep -qF "$needle" "$LOG"; then
        echo "[test_sit] PASS: $label"
    else
        echo "[test_sit] FAIL: $label (expected '$needle')" >&2
        fail=1
    fi
}

check "self-test ran"             "[sit] self-test start"
check "tunnel add"                "[sit] PASS tunnel-add"
check "tunnel lookup"             "[sit] PASS tunnel-lookup"
check "6to4 prefix"               "[sit] PASS 6to4-prefix"
check "roundtrip byte-identical"  "[sit] PASS roundtrip-byte-identical"
check "reject wrong proto"        "[sit] PASS reject-wrong-proto"
check "reject wrong dst"          "[sit] PASS reject-wrong-dst"
check "sit PASS banner"           "[sit] PASS"
check "boot gate PASS"            "[boot:37.sit] PASS"

if [ "$fail" -ne 0 ]; then
    echo "[test_sit] FAIL"
    exit 1
fi

echo "[test_sit] PASS — native 6in4 / sit (RFC 4213): ENCAP prepends an outer IPv4 header (protocol 41) to a complete inner IPv6 packet with the correct outer Total Length and a valid outer IPv4 header checksum and carries the inner packet verbatim; the RFC 3056 6to4 prefix (2002::/16) derivation is verified; DECAP validates proto==41 + outer dst==endpoint, strips the outer header and recovers the inner IPv6 packet byte-identically; a wrong-protocol outer frame and a wrong-destination outer frame are both rejected"
