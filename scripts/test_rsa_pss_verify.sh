#!/usr/bin/env bash
# scripts/test_rsa_pss_verify.sh — RSA-PSS-SHA256 verify (V2) regression.
#
# Builds tests/test_rsa_pss_verify.ad as a userland x86_64 ELF, plants
# it at /bin/test_rsa_pss_verify, boots QEMU + hamsh, runs the binary,
# and greps the serial log for the [rsa_pss] PASS banner.
#
# The test feeds a real openssl-generated RSA-2048 self-signed cert
# (signed with rsa_padding_mode:pss, salt length 32, SHA-256 — the
# modern PSS profile) into V1's x509_parse then V2's rsa_pss_verify.
# Verifies a clean signature returns 1, and that flipping a byte in
# the signature returns 0.
#
# PASS criterion: "[rsa_pss] failures=0" AND "[rsa_pss] PASS" both
# present in the serial log. Shape borrowed from
# scripts/test_x509_walker.sh.

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-vmlinux.elf
HAMSH_ELF=build/user/hamsh.elf
TEST_ELF=build/user/test_rsa_pss_verify.elf

echo "[test_rsa_pss_verify] (1/5) Build userland (hamsh + coreutils)"
bash scripts/build_user.sh >/dev/null
bash scripts/build_modules.sh >/dev/null

echo "[test_rsa_pss_verify] (2/5) Build tests/test_rsa_pss_verify.ad -> $TEST_ELF"
python3 -m compiler.adder compile \
    --target=x86_64-adder-user \
    tests/test_rsa_pss_verify.ad \
    -o "$TEST_ELF" >/dev/null

echo "[test_rsa_pss_verify] (3/5) Plant /init = hamsh + /bin/test_rsa_pss_verify in cpio"
INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py >/dev/null

echo "[test_rsa_pss_verify] (4/5) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

echo "[test_rsa_pss_verify] (5/5) Boot QEMU + drive /bin/test_rsa_pss_verify via hamsh"
LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null' EXIT

set +e
(
    sleep 3
    printf '/bin/test_rsa_pss_verify\n'
    sleep 8
    printf 'exit\n'
    sleep 1
) | timeout 40s qemu-system-x86_64 \
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

echo "[test_rsa_pss_verify] --- captured output ---"
cat "$LOG"
echo "[test_rsa_pss_verify] --- end output ---"

fail=0

# Banner first — proves the fixture ran end to end.
if grep -F -q "[rsa_pss] start" "$LOG"; then
    echo "[test_rsa_pss_verify] OK: fixture ran"
else
    echo "[test_rsa_pss_verify] MISS: fixture banner missing"
    fail=1
fi

# Per-failure FAIL lines should NEVER appear when the verifier is clean.
if grep -F -q "[rsa_pss] FAIL:" "$LOG"; then
    echo "[test_rsa_pss_verify] MISS: per-assertion FAIL line(s) present:"
    grep -F "[rsa_pss] FAIL:" "$LOG" | sed 's/^/  /'
    fail=1
else
    echo "[test_rsa_pss_verify] OK: no per-assertion FAIL lines"
fi

# Aggregate count line — failures=0 is the bar.
if grep -F -q "[rsa_pss] failures=0" "$LOG"; then
    echo "[test_rsa_pss_verify] OK: failures=0"
else
    echo "[test_rsa_pss_verify] MISS: failures=0 absent"
    fail=1
fi

# Final PASS line — proves we reached the end of main().
if grep -F -q "[rsa_pss] PASS" "$LOG"; then
    echo "[test_rsa_pss_verify] OK: fixture reached PASS"
else
    echo "[test_rsa_pss_verify] MISS: PASS line absent"
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_rsa_pss_verify] FAIL (qemu rc=$rc)"
    exit 1
fi

echo "[test_rsa_pss_verify] PASS"
