#!/usr/bin/env bash
# scripts/test_rfc6979.sh — RFC 6979 deterministic-ECDSA-nonce KAT.
#
# Builds tests/test_rfc6979.ad as a userland x86_64 ELF, plants it at
# /bin/test_rfc6979, boots QEMU + hamsh, runs the binary, and greps
# the serial log for the [rfc6979] PASS banner.
#
# The fixture signs the two NIST P-256 / SHA-256 messages from
# RFC 6979 Appendix A.2.5 ("sample" and "test") with the RFC's test
# private key and asserts the resulting (r, s) match the published
# vectors byte-for-byte. Because the nonce is RFC 6979 deterministic,
# the signature is fixed — a wrong nonce or wrong DRBG would produce
# a completely different (r, s) and the KAT would catch it.
#
# PASS criterion: "[rfc6979] failures=0" AND "[rfc6979] PASS" both
# present in the serial log. Shape borrowed from
# scripts/test_ecdsa_verify.sh; the 90s timeout covers the bit-by-bit
# P-256 field arithmetic (two full signs is a few seconds in QEMU).

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf
TEST_ELF=build/user/test_rfc6979.elf

echo "[test_rfc6979] (1/5) Build userland (hamsh + coreutils)"
bash scripts/build_user.sh >/dev/null
bash scripts/build_modules.sh >/dev/null

echo "[test_rfc6979] (2/5) Build tests/test_rfc6979.ad -> $TEST_ELF"
python3 -m compiler.adder compile \
    --target=x86_64-adder-user \
    tests/test_rfc6979.ad \
    -o "$TEST_ELF" >/dev/null

echo "[test_rfc6979] (3/5) Plant /init = hamsh + /bin/test_rfc6979 in cpio"
INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py >/dev/null

echo "[test_rfc6979] (4/5) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

echo "[test_rfc6979] (5/5) Boot QEMU + drive /bin/test_rfc6979 via hamsh"
LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null' EXIT

set +e
(
    sleep 3
    printf '/bin/test_rfc6979\n'
    sleep 30
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

echo "[test_rfc6979] --- captured output ---"
cat "$LOG"
echo "[test_rfc6979] --- end output ---"

fail=0

if grep -F -q "[rfc6979] start" "$LOG"; then
    echo "[test_rfc6979] OK: fixture ran"
else
    echo "[test_rfc6979] MISS: fixture banner missing"
    fail=1
fi

if grep -F -q "[rfc6979] FAIL:" "$LOG"; then
    echo "[test_rfc6979] MISS: per-vector FAIL line(s) present:"
    grep -F "[rfc6979] FAIL:" "$LOG" | sed 's/^/  /'
    fail=1
else
    echo "[test_rfc6979] OK: no per-vector FAIL lines"
fi

if grep -F -q "[rfc6979] failures=0" "$LOG"; then
    echo "[test_rfc6979] OK: failures=0"
else
    echo "[test_rfc6979] MISS: failures=0 absent"
    fail=1
fi

if grep -F -q "[rfc6979] PASS" "$LOG"; then
    echo "[test_rfc6979] OK: fixture reached PASS"
else
    echo "[test_rfc6979] MISS: PASS line absent"
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_rfc6979] FAIL (qemu rc=$rc)"
    exit 1
fi

echo "[test_rfc6979] PASS"
