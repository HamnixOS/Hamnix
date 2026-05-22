#!/usr/bin/env bash
# scripts/test_x509_walker.sh — X.509 v3 walker (V1) regression.
#
# Builds tests/test_x509_walker.ad as a userland x86_64 ELF, plants it
# at /bin/test_x509_walker, boots QEMU + hamsh, runs the binary, and
# greps the serial log for the [x509] PASS banner.
#
# The test feeds a real openssl-generated ECDSA-P256 self-signed cert
# into lib/x509/x509.ad::x509_parse and asserts every field on the
# X509Cert struct (version, serial, sig_alg OID, issuer/subject DN,
# validity bytes, pubkey alg + bytes, basicConstraints, SAN dNSNames,
# TBS byte range, signature bytes) plus the x509_match_dns wildcard
# and case-insensitive rules.
#
# PASS criterion: "[x509] failures=0" AND "[x509] PASS" both present
# in the serial log. Shape borrowed from scripts/test_asn1_parser.sh.

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf
TEST_ELF=build/user/test_x509_walker.elf

echo "[test_x509_walker] (1/5) Build userland (hamsh + coreutils)"
bash scripts/build_user.sh >/dev/null
bash scripts/build_modules.sh >/dev/null

echo "[test_x509_walker] (2/5) Build tests/test_x509_walker.ad -> $TEST_ELF"
python3 -m compiler.adder compile \
    --target=x86_64-adder-user \
    tests/test_x509_walker.ad \
    -o "$TEST_ELF" >/dev/null

echo "[test_x509_walker] (3/5) Plant /init = hamsh + /bin/test_x509_walker in cpio"
INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py >/dev/null

echo "[test_x509_walker] (4/5) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

echo "[test_x509_walker] (5/5) Boot QEMU + drive /bin/test_x509_walker via hamsh"
LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null' EXIT

set +e
(
    sleep 3
    printf '/bin/test_x509_walker\n'
    sleep 3
    printf 'exit\n'
    sleep 1
) | timeout 25s qemu-system-x86_64 \
    -kernel "$ELF" \
    -smp 2 \
    -nographic \
    -no-reboot \
    -m 256M \
    -monitor none \
    -serial stdio \
    > "$LOG" 2>&1
rc=$?
set -e

echo "[test_x509_walker] --- captured output ---"
cat "$LOG"
echo "[test_x509_walker] --- end output ---"

fail=0

# Banner first — proves the fixture ran end to end.
if grep -F -q "[x509] start" "$LOG"; then
    echo "[test_x509_walker] OK: fixture ran"
else
    echo "[test_x509_walker] MISS: fixture banner missing"
    fail=1
fi

# Per-failure FAIL lines should NEVER appear when the walker is clean.
if grep -F -q "[x509] FAIL:" "$LOG"; then
    echo "[test_x509_walker] MISS: per-assertion FAIL line(s) present:"
    grep -F "[x509] FAIL:" "$LOG" | sed 's/^/  /'
    fail=1
else
    echo "[test_x509_walker] OK: no per-assertion FAIL lines"
fi

# Aggregate count line — failures=0 is the bar.
if grep -F -q "[x509] failures=0" "$LOG"; then
    echo "[test_x509_walker] OK: failures=0"
else
    echo "[test_x509_walker] MISS: failures=0 absent"
    fail=1
fi

# Final PASS line — proves we reached the end of main().
if grep -F -q "[x509] PASS" "$LOG"; then
    echo "[test_x509_walker] OK: fixture reached PASS"
else
    echo "[test_x509_walker] MISS: PASS line absent"
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_x509_walker] FAIL (qemu rc=$rc)"
    exit 1
fi

echo "[test_x509_walker] PASS"
