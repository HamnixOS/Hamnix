#!/usr/bin/env bash
# scripts/test_ipsec.sh — native IPsec ESP (transport mode, AES-GCM) self-test.
#
# Boots the kernel once with /etc/ipsec-test planted (ENABLE_IPSEC_TEST=1).
# init/main.ad at boot:37.ipsec calls ipsec_selftest() (drivers/net/ipsec.ad),
# a fully in-memory two-endpoint loopback test (NO external NIC required) that
# PROVES the native IPsec ESP data-plane (RFC 4303 transport mode, AES-GCM per
# RFC 4106):
#
#   * It installs an A->B Security Association pair sharing a key/SPI/salt
#     (slot 0 = A's outbound SA, slot 1 = B's inbound SA with the anti-replay
#     window, RFC 4303 §3.4.3).
#   * ENCAPsulates a known upper-layer payload (next-header 17 = UDP) into the
#     ESP packet SPI(4)|Seq(4)|ciphertext|ICV(16), AES-GCM-sealing the payload
#     plus the ESP trailer (pad|pad-len|next-header) with nonce = salt||seq and
#     AAD = SPI||seq (RFC 4106) — reusing the TLS AES-GCM AEAD (no new crypto).
#   * Proves the on-wire payload is genuine ciphertext (differs from plaintext).
#   * DECAPsulates it on B back to a BYTE-IDENTICAL plaintext + correct
#     next-header.
#   * Security properties, all verdicts from actual results:
#       - a flipped ciphertext byte -> GCM ICV mismatch -> REJECT, no plaintext;
#       - a flipped ICV byte        -> GCM ICV mismatch -> REJECT;
#       - a replayed (already-seen) seq -> anti-replay window REJECT;
#       - a fresh in-window seq (seq 2) -> ACCEPTED and advances the window;
#       - an old seq (1) after the window advanced -> REJECT;
#       - sequence numbers increase across multiple protected packets.
#
# Boot path: a raw 64-bit Hamnix ELF will NOT boot under `qemu -kernel` on this
# host; the _kernel_iso.sh PATH shim (sourced by _build_lock.sh) transparently
# wraps the ELFCLASS64 kernel in a BIOS GRUB ISO, so the `-kernel "$ELF"`
# invocation below boots through the ISO shim.
#
# Pass marker:  [ipsec] PASS
# Fail marker:  [ipsec] FAIL / self-test reported FAIL

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

export HAMNIX_BUILD_LOCK_TIMEOUT="${HAMNIX_BUILD_LOCK_TIMEOUT:-900}"

ELF=build/hamnix-kernel.elf

echo "[test_ipsec] (1/3) Build userland (init)"
bash scripts/build_user.sh >/dev/null

echo "[test_ipsec] (2/3) Build kernel with /etc/ipsec-test marker"
INIT_ELF=build/user/init.elf ENABLE_IPSEC_TEST=1 \
    python3 scripts/build_initramfs.py >/dev/null
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

LOG=$(mktemp)
# Restore the default initramfs afterwards + clean up the log.
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1 || true' EXIT

echo "[test_ipsec] (3/3) Boot QEMU"
set +e
timeout 320s qemu-system-x86_64 \
    -kernel "$ELF" \
    -smp 1 \
    -nographic -no-reboot -m 256M -monitor none -serial stdio \
    > "$LOG" 2>&1 < /dev/null
rc=$?
set -e

echo "[test_ipsec] --- captured (ipsec lines) ---"
grep -E '\[ipsec\]|\[boot:37.ipsec\]' "$LOG" || true
echo "[test_ipsec] --- end ---"

fail=0

if [ "$rc" -ne 0 ] && [ "$rc" -ne 124 ]; then
    echo "[test_ipsec] FAIL: qemu exited rc=$rc" >&2
    fail=1
fi

if grep -qF "[ipsec] FAIL" "$LOG"; then
    echo "[test_ipsec] FAIL: kernel self-test reported an internal failure" >&2
    fail=1
fi
if grep -qF "[boot:37.ipsec] FAIL" "$LOG"; then
    echo "[test_ipsec] FAIL: boot gate reported FAIL" >&2
    fail=1
fi

check() {
    local label="$1" needle="$2"
    if grep -qF "$needle" "$LOG"; then
        echo "[test_ipsec] PASS: $label"
    else
        echo "[test_ipsec] FAIL: $label (expected '$needle')" >&2
        fail=1
    fi
}

check "self-test ran"            "[ipsec] self-test start"
check "payload is ciphertext"    "[ipsec] PASS payload-is-ciphertext"
check "roundtrip byte-identical" "[ipsec] PASS roundtrip-byte-identical"
check "next-header recovered"    "[ipsec] PASS next-header=17(udp)"
check "reject tampered ct"       "[ipsec] PASS reject-tampered-ciphertext"
check "reject tampered icv"      "[ipsec] PASS reject-tampered-icv"
check "reject replayed seq"      "[ipsec] PASS reject-replayed-seq"
check "seq increments"           "[ipsec] PASS seq-increments (seq2=2)"
check "accept fresh in-window"   "[ipsec] PASS accept-fresh-in-window-seq"
check "window rejects old seq"   "[ipsec] PASS window-advanced-rejects-old-seq"
check "ipsec PASS banner"        "[ipsec] PASS"
check "boot gate PASS"           "[boot:37.ipsec] PASS"

if [ "$fail" -ne 0 ]; then
    echo "[test_ipsec] FAIL"
    exit 1
fi

echo "[test_ipsec] PASS — native IPsec ESP (RFC 4303 transport mode, AES-GCM per RFC 4106): an A->B SA pair shares a key/SPI/salt; a known payload is ENCAPsulated into SPI|seq|ciphertext|ICV (nonce=salt||seq, AAD=SPI||seq) reusing the TLS AES-GCM AEAD, proven to be real ciphertext, DECAPsulated back byte-identical with the correct next-header, and the security properties proven — tampered ciphertext/ICV fail the GCM ICV, a replayed seq is rejected by the sliding anti-replay window, a fresh in-window seq is accepted and advances the window, and sequence numbers increase across packets"
