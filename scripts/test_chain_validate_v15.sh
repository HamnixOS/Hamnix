#!/usr/bin/env bash
# scripts/test_chain_validate_v15.sh — Chain validation V6 regression:
# PKCS#1 v1.5 + SHA-256 dispatch (the residual that closed the
# "apt over HTTPS against ISRG-rooted mirrors" gap from V5).
#
# Builds tests/test_chain_validate_v15.ad as a userland x86_64 ELF,
# plants it at /bin/test_chain_validate_v15, boots QEMU + hamsh, runs
# the binary, and greps the serial log for the [chain_v15] PASS banner.
#
# The fixture loads a 2-cert chain (RSA-2048 leaf signed with
# sha256WithRSAEncryption by an RSA-2048 v1.5 self-signed root), seeds
# the CA store with the root, and exercises
# lib/x509/chain.ad::validate_cert_chain on:
#   - the legitimate v1.5 chain (expect 1)
#   - leaf v1.5 signature bit-flipped (expect 0)
#
# Timeout 120s — same shape as scripts/test_chain_validate.sh. RSA-2048
# modexp is a touch slower than ECDSA-P256 verify in QEMU; we do two
# full verifies (legit + tamper) per run.
#
# PASS criterion: "[chain_v15] failures=0" AND "[chain_v15] PASS" both
# present in the serial log.

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf
TEST_ELF=build/user/test_chain_validate_v15.elf

echo "[test_chain_validate_v15] (1/5) Build userland (hamsh + coreutils)"
bash scripts/build_user.sh >/dev/null
bash scripts/build_modules.sh >/dev/null

echo "[test_chain_validate_v15] (2/5) Build tests/test_chain_validate_v15.ad -> $TEST_ELF"
python3 -m compiler.adder compile \
    --target=x86_64-adder-user \
    tests/test_chain_validate_v15.ad \
    -o "$TEST_ELF" >/dev/null

echo "[test_chain_validate_v15] (3/5) Plant /init = hamsh + /bin/test_chain_validate_v15 in cpio"
INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py >/dev/null

echo "[test_chain_validate_v15] (4/5) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

echo "[test_chain_validate_v15] (5/5) Boot QEMU + drive /bin/test_chain_validate_v15 via hamsh"
LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null' EXIT

set +e
(
    sleep 3
    printf '/bin/test_chain_validate_v15\n'
    sleep 80
    printf 'exit\n'
    sleep 1
) | timeout 120s qemu-system-x86_64 \
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

echo "[test_chain_validate_v15] --- captured output ---"
cat "$LOG"
echo "[test_chain_validate_v15] --- end output ---"

fail=0

# Banner first — proves the fixture ran end to end.
if grep -F -q "[chain_v15] start" "$LOG"; then
    echo "[test_chain_validate_v15] OK: fixture ran"
else
    echo "[test_chain_validate_v15] MISS: fixture banner missing"
    fail=1
fi

# Per-failure FAIL lines should NEVER appear when validate is clean.
if grep -F -q "[chain_v15] FAIL:" "$LOG"; then
    echo "[test_chain_validate_v15] MISS: per-assertion FAIL line(s) present:"
    grep -F "[chain_v15] FAIL:" "$LOG" | sed 's/^/  /'
    fail=1
else
    echo "[test_chain_validate_v15] OK: no per-assertion FAIL lines"
fi

# Aggregate count line — failures=0 is the bar.
if grep -F -q "[chain_v15] failures=0" "$LOG"; then
    echo "[test_chain_validate_v15] OK: failures=0"
else
    echo "[test_chain_validate_v15] MISS: failures=0 absent"
    fail=1
fi

# Final PASS line — proves we reached the end of main().
if grep -F -q "[chain_v15] PASS" "$LOG"; then
    echo "[test_chain_validate_v15] OK: fixture reached PASS"
else
    echo "[test_chain_validate_v15] MISS: PASS line absent"
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_chain_validate_v15] FAIL (qemu rc=$rc)"
    exit 1
fi

echo "[test_chain_validate_v15] PASS"
