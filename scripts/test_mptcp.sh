#!/usr/bin/env bash
# scripts/test_mptcp.sh — native Multipath TCP (MPTCP, RFC 8684) connection +
# two-subflow data-reassembly self-test.
#
# Boots the kernel once with /etc/mptcp-test planted (ENABLE_MPTCP_TEST=1).
# init/main.ad at boot:37.mptcp calls mptcp_selftest() (drivers/net/mptcp.ad),
# a fully in-memory two-endpoint / two-subflow loopback test (NO external NIC
# required) that PROVES the core of MPTCP (RFC 8684):
#
#   * The MP_CAPABLE handshake (RFC 8684 §3.1):
#       A --SYN  MP_CAPABLE(Key-A)----------------------------> B
#       A <--SYN/ACK MP_CAPABLE(Key-B)------------------------- B
#       A --ACK  MP_CAPABLE(Key-A, Key-B)---------------------> B
#     From the peer's key each side derives token = MSB-32 of SHA-256(key) and
#     IDSN = LSB-64 of SHA-256(key) (reusing fs/sha256.ad, with an in-file
#     HMAC-SHA256 built on the shared one-shot SHA-256).
#   * MP_JOIN of a second subflow (RFC 8684 §3.2): token-addressed, with the
#     HMAC challenge/response over the two random nonces keyed by the two
#     connection keys, verified in BOTH directions.
#   * The DSS option (RFC 8684 §3.3): it maps subflow-level TCP sequence space
#     to the connection-level Data Sequence Number and carries the DSS data-
#     level checksum. Data sent across TWO subflows reassembles byte-identically
#     in connection-level (DSN) order, including an out-of-order arrival across
#     subflows that is buffered and released in DSN order.
#   * DATA_FIN / connection close (RFC 8684 §3.3.3).
#   * Security properties, all verdicts from actual encoded/decoded bytes:
#       - a wrong MP_JOIN HMAC is rejected;
#       - a corrupted DSS checksum is detected/rejected;
#       - a wrong token does not join.
#
# Boot path: a raw 64-bit Hamnix ELF will NOT boot under `qemu -kernel` on this
# host; the _kernel_iso.sh PATH shim (sourced by _build_lock.sh) transparently
# wraps the ELFCLASS64 kernel in a BIOS GRUB ISO, so the `-kernel "$ELF"`
# invocation below boots through the ISO shim.
#
# Pass marker:  [mptcp] PASS
# Fail marker:  [mptcp] FAIL / self-test reported FAIL

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

export HAMNIX_BUILD_LOCK_TIMEOUT="${HAMNIX_BUILD_LOCK_TIMEOUT:-900}"

ELF=build/hamnix-kernel.elf

echo "[test_mptcp] (1/3) Build userland (init)"
bash scripts/build_user.sh >/dev/null

echo "[test_mptcp] (2/3) Build kernel with /etc/mptcp-test marker"
INIT_ELF=build/user/init.elf ENABLE_MPTCP_TEST=1 \
    python3 scripts/build_initramfs.py >/dev/null
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

LOG=$(mktemp)
# Restore the default initramfs afterwards + clean up the log.
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1 || true' EXIT

echo "[test_mptcp] (3/3) Boot QEMU"
set +e
timeout 320s qemu-system-x86_64 \
    -kernel "$ELF" \
    -smp 1 \
    -nographic -no-reboot -m 256M -monitor none -serial stdio \
    > "$LOG" 2>&1 < /dev/null
rc=$?
set -e

echo "[test_mptcp] --- captured (mptcp lines) ---"
grep -E '\[mptcp\]|\[boot:37.mptcp\]' "$LOG" || true
echo "[test_mptcp] --- end ---"

fail=0

if [ "$rc" -ne 0 ] && [ "$rc" -ne 124 ]; then
    echo "[test_mptcp] FAIL: qemu exited rc=$rc" >&2
    fail=1
fi

if grep -qF "[mptcp] FAIL" "$LOG"; then
    echo "[test_mptcp] FAIL: kernel self-test reported an internal failure" >&2
    fail=1
fi
if grep -qF "[boot:37.mptcp] FAIL" "$LOG"; then
    echo "[test_mptcp] FAIL: boot gate reported FAIL" >&2
    fail=1
fi

check() {
    local label="$1" needle="$2"
    if grep -qF "$needle" "$LOG"; then
        echo "[test_mptcp] PASS: $label"
    else
        echo "[test_mptcp] FAIL: $label (expected '$needle')" >&2
        fail=1
    fi
}

check "self-test ran"             "[mptcp] self-test start"
check "mp-capable handshake"      "[mptcp] PASS mp-capable-handshake"
check "mp-join hmac-B verified"   "[mptcp] PASS mp-join-hmac-B-verified"
check "mp-join hmac-A verified"   "[mptcp] PASS mp-join-hmac-A-verified"
check "reject wrong join hmac"    "[mptcp] PASS reject-wrong-join-hmac"
check "reject wrong token"        "[mptcp] PASS reject-wrong-token"
check "dss in-order 2 subflows"   "[mptcp] PASS dss-inorder-2subflows"
check "dss out-of-order buffered" "[mptcp] PASS dss-out-of-order-buffered"
check "dss gap filled drained"    "[mptcp] PASS dss-gap-filled-drained"
check "dss reassembly identical"  "[mptcp] PASS dss-reassembly-byte-identical"
check "reject corrupted dss csum" "[mptcp] PASS reject-corrupted-dss-checksum"
check "data-fin close"            "[mptcp] PASS data-fin-close"
check "mptcp PASS banner"         "[mptcp] PASS"
check "boot gate PASS"            "[boot:37.mptcp] PASS"

if [ "$fail" -ne 0 ]; then
    echo "[test_mptcp] FAIL"
    exit 1
fi

echo "[test_mptcp] PASS — native MPTCP (RFC 8684): the MP_CAPABLE handshake exchanges per-side keys and each side derives the token (MSB-32 of SHA-256(key)) + IDSN (LSB-64) consistently; MP_JOIN brings up a second subflow token-addressed with an HMAC-SHA256 challenge/response over random nonces keyed by the two connection keys, verified in both directions; the DSS option maps subflow sequence space to the connection-level Data Sequence Number and carries the DSS data-level checksum, so data split across TWO subflows reassembles byte-identically in DSN order (an out-of-order cross-subflow arrival is buffered and released in DSN order) and a DATA_FIN closes the connection; a wrong MP_JOIN HMAC is rejected, a corrupted DSS checksum is detected, and a wrong token does not join"
