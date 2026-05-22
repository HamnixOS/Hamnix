#!/usr/bin/env bash
# scripts/test_chain_validate.sh — Chain validation (V4) regression.
#
# Builds tests/test_chain_validate.ad as a userland x86_64 ELF, plants
# it at /bin/test_chain_validate, boots QEMU + hamsh, runs the binary,
# and greps the serial log for the [chain] PASS banner.
#
# The test loads an openssl-generated 2-cert chain (CN=test.hamnix.local
# leaf signed by a CN=Hamnix Test CA root; both ECDSA-P256), seeds the
# CA store with the root, and exercises lib/x509/chain.ad::
# validate_cert_chain on:
#   - the legitimate chain (expect 1)
#   - leaf signature bit-flipped (expect 0)
#   - wrong host (expect 0)
#   - now_unix past not_after (expect 0)
#   - CA store emptied (expect 0)
#
# Timeout 90s — same budget as test_ecdsa_verify.sh because the leaf
# signature verify path drives a full ECDSA-P256 verify (~5s in QEMU
# without Solinas/Montgomery). The legitimate case + the sig-flip
# tamper case together do two full verifies; everything else short-
# circuits before reaching the EC math.
#
# PASS criterion: "[chain] failures=0" AND "[chain] PASS" both present
# in the serial log. Shape borrowed from scripts/test_ecdsa_verify.sh.

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf
TEST_ELF=build/user/test_chain_validate.elf

echo "[test_chain_validate] (1/5) Build userland (hamsh + coreutils)"
bash scripts/build_user.sh >/dev/null
bash scripts/build_modules.sh >/dev/null

echo "[test_chain_validate] (2/5) Build tests/test_chain_validate.ad -> $TEST_ELF"
python3 -m compiler.adder compile \
    --target=x86_64-adder-user \
    tests/test_chain_validate.ad \
    -o "$TEST_ELF" >/dev/null

echo "[test_chain_validate] (3/5) Plant /init = hamsh + /bin/test_chain_validate in cpio"
INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py >/dev/null

echo "[test_chain_validate] (4/5) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

echo "[test_chain_validate] (5/5) Boot QEMU + drive /bin/test_chain_validate via hamsh"
LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null' EXIT

set +e
(
    sleep 3
    printf '/bin/test_chain_validate\n'
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

echo "[test_chain_validate] --- captured output ---"
cat "$LOG"
echo "[test_chain_validate] --- end output ---"

fail=0

# Banner first — proves the fixture ran end to end.
if grep -F -q "[chain] start" "$LOG"; then
    echo "[test_chain_validate] OK: fixture ran"
else
    echo "[test_chain_validate] MISS: fixture banner missing"
    fail=1
fi

# Per-failure FAIL lines should NEVER appear when validate is clean.
if grep -F -q "[chain] FAIL:" "$LOG"; then
    echo "[test_chain_validate] MISS: per-assertion FAIL line(s) present:"
    grep -F "[chain] FAIL:" "$LOG" | sed 's/^/  /'
    fail=1
else
    echo "[test_chain_validate] OK: no per-assertion FAIL lines"
fi

# Aggregate count line — failures=0 is the bar.
if grep -F -q "[chain] failures=0" "$LOG"; then
    echo "[test_chain_validate] OK: failures=0"
else
    echo "[test_chain_validate] MISS: failures=0 absent"
    fail=1
fi

# Final PASS line — proves we reached the end of main().
if grep -F -q "[chain] PASS" "$LOG"; then
    echo "[test_chain_validate] OK: fixture reached PASS"
else
    echo "[test_chain_validate] MISS: PASS line absent"
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_chain_validate] FAIL (qemu rc=$rc)"
    exit 1
fi

echo "[test_chain_validate] PASS"
