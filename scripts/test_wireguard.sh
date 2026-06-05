#!/usr/bin/env bash
# scripts/test_wireguard.sh — native WireGuard (Noise_IKpsk2 over UDP) self-test.
#
# Boots the kernel once with /etc/wireguard-test planted (ENABLE_WIREGUARD_TEST=1).
# init/main.ad at boot:37.wireguard calls wireguard_selftest()
# (drivers/net/wireguard.ad), a fully in-memory two-peer loopback test (NO
# external NIC required) that PROVES the native WireGuard protocol:
#
#   * Known-answer tests prove the crypto core BEFORE any protocol is trusted:
#       - RFC 8439 ChaCha20-Poly1305 AEAD vector (ciphertext + tag byte-exact,
#         plus a round-trip open) — reuses the TLS ChaCha20-Poly1305.
#       - RFC 7748 X25519 scalar-multiplication vector — reuses the TLS X25519.
#       - BLAKE2s("abc") official vector — drivers/net/wg_crypto.ad BLAKE2s.
#   * The full Noise_IKpsk2 handshake between two peers A and B, each with a
#     static X25519 keypair and a shared pre-shared key:
#       - A builds the handshake-initiation (ephemeral pubkey + AEAD-sealed
#         static key + AEAD-sealed timestamp), B consumes it and authenticates
#         A's static key; both sides' chaining-key C and hash H are asserted to
#         MATCH after the initiation.
#       - B builds the handshake-response (ephemeral pubkey + AEAD-sealed empty,
#         psk-mixed) and derives its transport keys; A consumes it and derives
#         its transport keys.
#       - The derived transport keys are asserted to CROSS-MATCH
#         (A.send == B.recv and A.recv == B.send) — proving a real shared secret.
#   * A transport data message round-trips byte-identical A->B (the on-wire
#     payload is proven to be real ciphertext) and a reply round-trips B->A.
#   * Security properties: a wrong key, a replayed counter, and a tampered
#     ciphertext are each REJECTED — all verdicts computed from actual results.
#
# Boot path: a raw 64-bit Hamnix ELF will NOT boot under `qemu -kernel` on this
# host; the _kernel_iso.sh PATH shim (sourced by _build_lock.sh) transparently
# wraps the ELFCLASS64 kernel in a BIOS GRUB ISO, so the `-kernel "$ELF"`
# invocation below boots through the ISO shim.
#
# Pass marker:  [wireguard] PASS
# Fail marker:  [wireguard] FAIL / self-test reported FAIL

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

export HAMNIX_BUILD_LOCK_TIMEOUT="${HAMNIX_BUILD_LOCK_TIMEOUT:-900}"

ELF=build/hamnix-kernel.elf

echo "[test_wireguard] (1/3) Build userland (init)"
bash scripts/build_user.sh >/dev/null

echo "[test_wireguard] (2/3) Build kernel with /etc/wireguard-test marker"
INIT_ELF=build/user/init.elf ENABLE_WIREGUARD_TEST=1 \
    python3 scripts/build_initramfs.py >/dev/null
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

LOG=$(mktemp)
# Restore the default initramfs afterwards + clean up the log.
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1 || true' EXIT

echo "[test_wireguard] (3/3) Boot QEMU"
set +e
timeout 320s qemu-system-x86_64 \
    -kernel "$ELF" \
    -smp 1 \
    -nographic -no-reboot -m 256M -monitor none -serial stdio \
    > "$LOG" 2>&1 < /dev/null
rc=$?
set -e

echo "[test_wireguard] --- captured (wireguard lines) ---"
grep -E '\[wireguard\]|\[boot:37.wireguard\]' "$LOG" || true
echo "[test_wireguard] --- end ---"

fail=0

if [ "$rc" -ne 0 ] && [ "$rc" -ne 124 ]; then
    echo "[test_wireguard] FAIL: qemu exited rc=$rc" >&2
    fail=1
fi

if grep -qF "[wireguard] FAIL" "$LOG"; then
    echo "[test_wireguard] FAIL: kernel self-test reported an internal failure" >&2
    fail=1
fi
if grep -qF "[boot:37.wireguard] FAIL" "$LOG"; then
    echo "[test_wireguard] FAIL: boot gate reported FAIL" >&2
    fail=1
fi

check() {
    local label="$1" needle="$2"
    if grep -qF "$needle" "$LOG"; then
        echo "[test_wireguard] PASS: $label"
    else
        echo "[test_wireguard] FAIL: $label (expected '$needle')" >&2
        fail=1
    fi
}

check "self-test ran"            "[wireguard] self-test start"
check "chacha20poly1305 KAT"     "[wireguard] PASS kat-chacha20poly1305 (RFC 8439)"
check "x25519 KAT"               "[wireguard] PASS kat-x25519 (RFC 7748)"
check "blake2s KAT"              "[wireguard] PASS kat-blake2s (RFC 7693)"
check "initiation built"         "[wireguard] PASS initiation-built len="
check "initiation consumed C+H"  "[wireguard] PASS initiation-consumed C+H-match"
check "response built"           "[wireguard] PASS response-built len="
check "response consumed"        "[wireguard] PASS response-consumed"
check "transport keys match"     "[wireguard] PASS transport-keys-match"
check "roundtrip A->B"           "[wireguard] PASS transport-roundtrip-A-to-B"
check "roundtrip B->A"           "[wireguard] PASS transport-roundtrip-B-to-A"
check "reject wrong key"         "[wireguard] PASS reject-wrong-key"
check "reject replay"            "[wireguard] PASS reject-replay"
check "reject tampered ct"       "[wireguard] PASS reject-tampered-ciphertext"
check "wireguard PASS banner"    "[wireguard] PASS"
check "boot gate PASS"           "[boot:37.wireguard] PASS"

if [ "$fail" -ne 0 ]; then
    echo "[test_wireguard] FAIL"
    exit 1
fi

echo "[test_wireguard] PASS — native WireGuard (Noise_IKpsk2 over UDP): RFC 8439 ChaCha20-Poly1305, RFC 7748 X25519 and BLAKE2s known-answer vectors verified, the full handshake (initiation + response, with a pre-shared key) completed deriving cross-matching transport keys via X25519 ECDH + HKDF-BLAKE2s, an inner packet round-trips byte-identical A->B and B->A via ChaCha20-Poly1305 transport messages, and the security properties proven — wrong key, replayed counter and tampered ciphertext all rejected"
