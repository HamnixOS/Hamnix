#!/usr/bin/env bash
# scripts/test_ecdsa_verify.sh — ECDSA-P256 verify (V3) regression.
#
# Builds tests/test_ecdsa_verify.ad as a userland x86_64 ELF, plants
# it at /bin/test_ecdsa_verify, boots QEMU + hamsh, runs the binary,
# and greps the serial log for the [ecdsa] PASS banner.
#
# The test feeds a real openssl-generated ECDSA-P256 self-signed cert
# (same DER bytes used by tests/test_x509_walker.ad) into x509_parse,
# pulls (TBS bytes, signature, pubkey) off the X509Cert struct, then
# drives them through lib/ecdsa/ecdsa.ad::ecdsa_p256_verify. It asserts:
#   - legitimate sig verifies (returns 1)
#   - flipping one bit in the sig flips the result (returns 0)
#   - flipping one bit in the TBS flips the result (returns 0)
#   - restoring the TBS byte restores the result (returns 1)
#   - a DER signature with r == 0 is malformed (returns -1)
#   - garbage DER is malformed (returns -1)
#
# Timeout is bumped to 60s vs the 25s used by the asn1/x509 fixtures —
# the bit-by-bit field arithmetic in lib/ec/p256.ad is correctness-
# tuned (no Solinas / Montgomery yet), so a full verify takes ~5s in
# QEMU rather than the millisecond budget the parser tests run on.
#
# PASS criterion: "[ecdsa] failures=0" AND "[ecdsa] PASS" both present
# in the serial log. Shape borrowed from scripts/test_x509_walker.sh.

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf
TEST_ELF=build/user/test_ecdsa_verify.elf

echo "[test_ecdsa_verify] (1/5) Build userland (hamsh + coreutils)"
bash scripts/build_user.sh >/dev/null
bash scripts/build_modules.sh >/dev/null

echo "[test_ecdsa_verify] (2/5) Build tests/test_ecdsa_verify.ad -> $TEST_ELF"
python3 -m compiler.adder compile \
    --target=x86_64-adder-user \
    tests/test_ecdsa_verify.ad \
    -o "$TEST_ELF" >/dev/null

echo "[test_ecdsa_verify] (3/5) Plant /init = hamsh + /bin/test_ecdsa_verify in cpio"
INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py >/dev/null

echo "[test_ecdsa_verify] (4/5) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

echo "[test_ecdsa_verify] (5/5) Boot QEMU + drive /bin/test_ecdsa_verify via hamsh"
LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null' EXIT

set +e
(
    sleep 3
    printf '/bin/test_ecdsa_verify\n'
    sleep 55
    printf 'exit\n'
    sleep 1
) | timeout 90s qemu-system-x86_64 \
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

echo "[test_ecdsa_verify] --- captured output ---"
cat "$LOG"
echo "[test_ecdsa_verify] --- end output ---"

fail=0

# Banner first — proves the fixture ran end to end.
if grep -F -q "[ecdsa] start" "$LOG"; then
    echo "[test_ecdsa_verify] OK: fixture ran"
else
    echo "[test_ecdsa_verify] MISS: fixture banner missing"
    fail=1
fi

# Per-failure FAIL lines should NEVER appear when verify is clean.
if grep -F -q "[ecdsa] FAIL:" "$LOG"; then
    echo "[test_ecdsa_verify] MISS: per-assertion FAIL line(s) present:"
    grep -F "[ecdsa] FAIL:" "$LOG" | sed 's/^/  /'
    fail=1
else
    echo "[test_ecdsa_verify] OK: no per-assertion FAIL lines"
fi

# Aggregate count line — failures=0 is the bar.
if grep -F -q "[ecdsa] failures=0" "$LOG"; then
    echo "[test_ecdsa_verify] OK: failures=0"
else
    echo "[test_ecdsa_verify] MISS: failures=0 absent"
    fail=1
fi

# Final PASS line — proves we reached the end of main().
if grep -F -q "[ecdsa] PASS" "$LOG"; then
    echo "[test_ecdsa_verify] OK: fixture reached PASS"
else
    echo "[test_ecdsa_verify] MISS: PASS line absent"
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_ecdsa_verify] FAIL (qemu rc=$rc)"
    exit 1
fi

echo "[test_ecdsa_verify] PASS"
