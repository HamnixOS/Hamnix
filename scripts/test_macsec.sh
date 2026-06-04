#!/usr/bin/env bash
# scripts/test_macsec.sh — native MACsec (IEEE 802.1AE) GCM-AES-128 self-test.
#
# Boots the kernel once with /etc/macsec-test planted (ENABLE_MACSEC_TEST=1).
# init/main.ad at boot:37.macsec calls macsec_selftest() (drivers/net/macsec.ad),
# a fully in-memory test (NO external NIC required) that PROVES native MACsec
# link-layer authenticated encryption, GCM-AES-128 (the IEEE-default cipher
# suite), REUSING the AES-GCM-128 AEAD already in drivers/net/tls.ad:
#
#   * Known-answer test: runs the published McGrew/Viega GCM-AES-128 Test
#     Case 4 vector and asserts the ciphertext + tag are byte-exact, proving
#     the reused AEAD core is correct.
#   * PROTECT: a known inner Ethernet frame is turned into
#     dst|src|SecTAG|ciphertext|ICV where the SecTAG carries the MACsec
#     EtherType 0x88E5, the TCI/AN byte (V/ES/SC/SCB/E/C flags + 2-bit AN),
#     SL, a 32-bit Packet Number, and the 8-byte SCI; the IV is SCI||PN and
#     the AAD is dst+src+SecTAG per 802.1AE.
#   * The on-wire secure data is asserted to be genuine CIPHERTEXT (differs
#     from the plaintext) with a 16-byte ICV appended.
#   * VALIDATE: the ICV is verified and the payload decrypted, recovering the
#     inner Ethernet frame BYTE-FOR-BYTE.
#   * Security properties: a tampered ciphertext byte is REJECTED, a tampered
#     ICV is REJECTED, a replayed PN is REJECTED, and a wrong key (different
#     AN's SAK) fails the ICV — all verdicts computed from actual results.
#   * A second Secure Association (AN=1, distinct key) round-trips
#     independently with its own PN.
#
# Boot path: a raw 64-bit Hamnix ELF will NOT boot under `qemu -kernel` on
# this host; the _kernel_iso.sh PATH shim (sourced by _build_lock.sh)
# transparently wraps the ELFCLASS64 kernel in a BIOS GRUB ISO, so the
# `-kernel "$ELF"` invocation below boots through the ISO shim.
#
# Pass marker:  [macsec] PASS
# Fail marker:  [macsec] FAIL / self-test reported FAIL

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

export HAMNIX_BUILD_LOCK_TIMEOUT="${HAMNIX_BUILD_LOCK_TIMEOUT:-900}"

ELF=build/hamnix-kernel.elf

echo "[test_macsec] (1/3) Build userland (init)"
bash scripts/build_user.sh >/dev/null

echo "[test_macsec] (2/3) Build kernel with /etc/macsec-test marker"
INIT_ELF=build/user/init.elf ENABLE_MACSEC_TEST=1 \
    python3 scripts/build_initramfs.py >/dev/null
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

LOG=$(mktemp)
# Restore the default initramfs afterwards + clean up the log.
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1 || true' EXIT

echo "[test_macsec] (3/3) Boot QEMU"
set +e
timeout 320s qemu-system-x86_64 \
    -kernel "$ELF" \
    -smp 1 \
    -nographic -no-reboot -m 256M -monitor none -serial stdio \
    > "$LOG" 2>&1 < /dev/null
rc=$?
set -e

echo "[test_macsec] --- captured (macsec lines) ---"
grep -E '\[macsec\]|\[boot:37.macsec\]' "$LOG" || true
echo "[test_macsec] --- end ---"

fail=0

if [ "$rc" -ne 0 ] && [ "$rc" -ne 124 ]; then
    echo "[test_macsec] FAIL: qemu exited rc=$rc" >&2
    fail=1
fi

if grep -qF "[macsec] FAIL" "$LOG"; then
    echo "[test_macsec] FAIL: kernel self-test reported an internal failure" >&2
    fail=1
fi
if grep -qF "[boot:37.macsec] FAIL" "$LOG"; then
    echo "[test_macsec] FAIL: boot gate reported FAIL" >&2
    fail=1
fi

check() {
    local label="$1" needle="$2"
    if grep -qF "$needle" "$LOG"; then
        echo "[test_macsec] PASS: $label"
    else
        echo "[test_macsec] FAIL: $label (expected '$needle')" >&2
        fail=1
    fi
}

check "self-test ran"           "[macsec] self-test start"
check "gcm-aes-128 KAT"         "[macsec] PASS gcm-aes-128-kat"
check "protected length"        "[macsec] PASS protected-len="
check "sectag ethertype"        "[macsec] PASS sectag-ethertype=0x88E5"
check "tci flags SC/E/C"        "[macsec] PASS tci-flags-SC-E-C"
check "an 0"                    "[macsec] PASS an=0"
check "pn 1"                    "[macsec] PASS pn=1"
check "payload is ciphertext"   "[macsec] PASS payload-is-ciphertext"
check "roundtrip byte-ident"    "[macsec] PASS roundtrip-byte-identical"
check "reject tampered ct"      "[macsec] PASS reject-tampered-ciphertext"
check "reject tampered icv"     "[macsec] PASS reject-tampered-icv"
check "reject replayed pn"      "[macsec] PASS reject-replayed-pn"
check "reject wrong key"        "[macsec] PASS reject-wrong-key"
check "roundtrip AN1"           "[macsec] PASS roundtrip-an1-pn100"
check "macsec PASS banner"      "[macsec] PASS"
check "boot gate PASS"          "[boot:37.macsec] PASS"

if [ "$fail" -ne 0 ]; then
    echo "[test_macsec] FAIL"
    exit 1
fi

echo "[test_macsec] PASS — native MACsec (IEEE 802.1AE) GCM-AES-128 link-layer encryption: published GCM-AES-128 known-answer vector verified, inner Ethernet frame PROTECTed into dst|src|SecTAG(0x88E5,E/C/SC,AN,PN,SCI)|ciphertext|ICV (reusing the TLS AES-GCM AEAD), on-wire payload proven to be real ciphertext, byte-exact VALIDATE round-trip, and the security properties proven — tampered ciphertext/ICV rejected, replayed PN rejected, wrong key fails ICV — across two Secure Associations selectable by the AN"
