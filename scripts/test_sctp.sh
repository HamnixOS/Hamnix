#!/usr/bin/env bash
# scripts/test_sctp.sh — native SCTP (RFC 4960) association + reliable ordered
# delivery self-test.
#
# Boots the kernel once with /etc/sctp-test planted (ENABLE_SCTP_TEST=1).
# init/main.ad at boot:37.sctp calls sctp_selftest() (drivers/net/sctp.ad), a
# fully in-memory two-endpoint loopback test (NO external NIC required) that
# PROVES the core of the SCTP protocol (RFC 4960):
#
#   * The 4-way association handshake (RFC 4960 §5.1):
#       A --INIT(initiate tag Ta)-------------------------> B
#       A <--INIT ACK(initiate tag Tb, State Cookie)------- B
#       A --COOKIE ECHO(State Cookie)---------------------> B
#       A <--COOKIE ACK------------------------------------ B
#     Each peer's initiate tag is echoed by the OTHER peer as the Verification
#     Tag on every subsequent packet; a wrong Verification Tag is discarded.
#   * SCTP common header (sport|dport|vtag|checksum) + chunk TLV framing with
#     4-byte chunk padding; the checksum is CRC32c (RFC 3309), reusing the
#     kernel's existing fs/crc32c.ad (the same Castagnoli code ext4 uses).
#   * Reliable, in-order DATA delivery on stream 0 (RFC 4960 §3.3.1, §6):
#     DATA chunks carry a TSN + stream id + stream sequence number; the receiver
#     returns SACK chunks (cumulative TSN ack + gap-ack blocks).
#   * Properties, all verdicts from actual encoded/decoded wire bytes:
#       - ordered delivery reassembles the byte stream byte-identically;
#       - an out-of-order arrival is BUFFERED (cum TSN does not advance);
#       - a SACK reflects the missing TSN as a gap-ack block;
#       - retransmitting the missing TSN closes the gap + advances the
#         cumulative TSN ack, draining the buffered chunk in stream order;
#       - the full reassembled stream equals the known reference message;
#       - a packet with a wrong Verification Tag is rejected;
#       - a packet with a corrupted byte fails the CRC32c check and is dropped.
#
# Boot path: a raw 64-bit Hamnix ELF will NOT boot under `qemu -kernel` on this
# host; the _kernel_iso.sh PATH shim (sourced by _build_lock.sh) transparently
# wraps the ELFCLASS64 kernel in a BIOS GRUB ISO, so the `-kernel "$ELF"`
# invocation below boots through the ISO shim.
#
# Pass marker:  [sctp] PASS
# Fail marker:  [sctp] FAIL / self-test reported FAIL

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

export HAMNIX_BUILD_LOCK_TIMEOUT="${HAMNIX_BUILD_LOCK_TIMEOUT:-900}"

ELF=build/hamnix-kernel.elf

echo "[test_sctp] (1/3) Build userland (init)"
bash scripts/build_user.sh >/dev/null

echo "[test_sctp] (2/3) Build kernel with /etc/sctp-test marker"
INIT_ELF=build/user/init.elf ENABLE_SCTP_TEST=1 \
    python3 scripts/build_initramfs.py >/dev/null
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

LOG=$(mktemp)
# Restore the default initramfs afterwards + clean up the log.
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1 || true' EXIT

echo "[test_sctp] (3/3) Boot QEMU"
set +e
timeout 320s qemu-system-x86_64 \
    -kernel "$ELF" \
    -smp 1 \
    -nographic -no-reboot -m 256M -monitor none -serial stdio \
    > "$LOG" 2>&1 < /dev/null
rc=$?
set -e

echo "[test_sctp] --- captured (sctp lines) ---"
grep -E '\[sctp\]|\[boot:37.sctp\]' "$LOG" || true
echo "[test_sctp] --- end ---"

fail=0

if [ "$rc" -ne 0 ] && [ "$rc" -ne 124 ]; then
    echo "[test_sctp] FAIL: qemu exited rc=$rc" >&2
    fail=1
fi

if grep -qF "[sctp] FAIL" "$LOG"; then
    echo "[test_sctp] FAIL: kernel self-test reported an internal failure" >&2
    fail=1
fi
if grep -qF "[boot:37.sctp] FAIL" "$LOG"; then
    echo "[test_sctp] FAIL: boot gate reported FAIL" >&2
    fail=1
fi

check() {
    local label="$1" needle="$2"
    if grep -qF "$needle" "$LOG"; then
        echo "[test_sctp] PASS: $label"
    else
        echo "[test_sctp] FAIL: $label (expected '$needle')" >&2
        fail=1
    fi
}

check "self-test ran"             "[sctp] self-test start"
check "4-way handshake"           "[sctp] PASS handshake-4way"
check "reject bad vtag"           "[sctp] PASS reject-bad-verification-tag"
check "reject bad crc32c"         "[sctp] PASS reject-bad-crc32c"
check "ordered delivery"          "[sctp] PASS ordered-delivery"
check "out-of-order buffered"     "[sctp] PASS out-of-order-buffered"
check "sack reports gap"          "[sctp] PASS sack-reports-gap"
check "retransmit closes gap"     "[sctp] PASS retransmit-closes-gap"
check "gap closed cumack"         "[sctp] PASS gap-closed-cumack-advanced"
check "reassembly identical"      "[sctp] PASS reassembly-byte-identical"
check "sctp PASS banner"          "[sctp] PASS"
check "boot gate PASS"            "[boot:37.sctp] PASS"

if [ "$fail" -ne 0 ]; then
    echo "[test_sctp] FAIL"
    exit 1
fi

echo "[test_sctp] PASS — native SCTP (RFC 4960): the 4-way association handshake (INIT -> INIT ACK with a State Cookie -> COOKIE ECHO -> COOKIE ACK) carries and verifies the per-direction Verification Tags; the SCTP common header + chunk TLV framing is checksummed with CRC32c (RFC 3309, reusing fs/crc32c.ad); reliable in-order DATA delivery reassembles a known multi-chunk byte stream identically, an out-of-order arrival is buffered (cum TSN held), a SACK reports the missing TSN as a gap-ack block, and a retransmit closes the gap + advances the Cumulative TSN Ack draining the buffered chunk in stream order; a wrong Verification Tag is rejected and a corrupted packet fails the CRC32c and is dropped"
