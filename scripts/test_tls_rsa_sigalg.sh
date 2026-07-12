#!/usr/bin/env bash
# scripts/test_tls_rsa_sigalg.sh — FAST, QEMU-free gate for the PKCS#1 v1.5
# signature-algorithm dispatch in lib/x509/chain.ad.
#
# Compiles tests/test_tls_rsa_sigalg_chain.ad (a checked-in, deterministic
# fixture of three real RSA-2048 root->inter->leaf chains signed with
# sha256/sha384/sha512WithRSAEncryption, plus a tamper case) for the
# x86_64-linux host target and runs it directly — no QEMU. This guards the
# SHA-384 / SHA-512 RSA dispatch OFFLINE, complementing the live-internet
# gate scripts/test_tls_real_chain.sh.
#
# Case (2) mirrors the real www.microsoft.com chain (SHA-384 top to bottom)
# that now validates to the baked DigiCert Global Root G2 anchor.
#
# Regenerate the fixture with: python3 scripts/gen_tls_rsa_sigalg_fixture.py
#
# PASS criterion: "[sigalg] PASS" AND "[sigalg] failures=0".

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/test_tls_rsa_sigalg"
FIX="tests/test_tls_rsa_sigalg_chain.ad"
mkdir -p "$OUT"

echo "[sigalg] compiling $FIX for x86_64-linux ..."
if ! python3 -m compiler.adder compile --target=x86_64-linux \
        "$FIX" -o "$BIN" 2>"$OUT/sigalg_compile.log"; then
    echo "[sigalg] FAIL: fixture did not compile"; cat "$OUT/sigalg_compile.log"; exit 1
fi

DUMP="$OUT/sigalg_dump.txt"
if ! "$BIN" >"$DUMP" 2>&1; then
    echo "[sigalg] FAIL: fixture exited non-zero"; cat "$DUMP"; exit 1
fi
cat "$DUMP"

if grep -Fq "[sigalg] FAIL" "$DUMP"; then
    echo "[sigalg] FAIL: per-case failure present"; exit 1
fi
if ! grep -Fq "[sigalg] failures=0" "$DUMP"; then
    echo "[sigalg] FAIL: failures=0 absent"; exit 1
fi
if ! grep -Fq "[sigalg] PASS" "$DUMP"; then
    echo "[sigalg] FAIL: PASS banner absent"; exit 1
fi
echo "[sigalg] PASS"
