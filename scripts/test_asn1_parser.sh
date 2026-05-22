#!/usr/bin/env bash
# scripts/test_asn1_parser.sh — ASN.1 DER parser (V0) regression.
#
# Builds tests/test_asn1_parser.ad as a userland x86_64 ELF, plants it
# at /bin/test_asn1_parser, boots QEMU + hamsh, runs the binary, and
# greps the serial log for the [asn1] PASS banner.
#
# The test covers every primitive reader in lib/asn1/asn1.ad:
# asn1_read_tlv (raw), asn1_read_sequence, asn1_read_set,
# asn1_read_integer, asn1_read_oid, asn1_read_octet_string,
# asn1_read_bit_string, asn1_read_utctime, asn1_skip, asn1_remaining,
# and the OID constant table. Plus malformed-input cases: truncated
# body, indefinite-length form (BER), length-of-length overflow, and
# wrong-tag rejection at typed readers.
#
# PASS criterion: "[asn1] failures=0" AND "[asn1] PASS" both present
# in the serial log. Shape borrowed from scripts/test_9p_codec.sh.

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf
TEST_ELF=build/user/test_asn1_parser.elf

echo "[test_asn1_parser] (1/5) Build userland (hamsh + coreutils)"
bash scripts/build_user.sh >/dev/null
bash scripts/build_modules.sh >/dev/null

echo "[test_asn1_parser] (2/5) Build tests/test_asn1_parser.ad -> $TEST_ELF"
python3 -m compiler.adder compile \
    --target=x86_64-adder-user \
    tests/test_asn1_parser.ad \
    -o "$TEST_ELF" >/dev/null

echo "[test_asn1_parser] (3/5) Plant /init = hamsh + /bin/test_asn1_parser in cpio"
INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py >/dev/null

echo "[test_asn1_parser] (4/5) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

echo "[test_asn1_parser] (5/5) Boot QEMU + drive /bin/test_asn1_parser via hamsh"
LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null' EXIT

set +e
(
    sleep 3
    printf '/bin/test_asn1_parser\n'
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

echo "[test_asn1_parser] --- captured output ---"
cat "$LOG"
echo "[test_asn1_parser] --- end output ---"

fail=0

# Banner first — proves the fixture ran end to end.
if grep -F -q "[asn1] start" "$LOG"; then
    echo "[test_asn1_parser] OK: fixture ran"
else
    echo "[test_asn1_parser] MISS: fixture banner missing"
    fail=1
fi

# Per-failure FAIL lines should NEVER appear when the parser is clean.
if grep -F -q "[asn1] FAIL:" "$LOG"; then
    echo "[test_asn1_parser] MISS: per-assertion FAIL line(s) present:"
    grep -F "[asn1] FAIL:" "$LOG" | sed 's/^/  /'
    fail=1
else
    echo "[test_asn1_parser] OK: no per-assertion FAIL lines"
fi

# Aggregate count line — failures=0 is the bar.
if grep -F -q "[asn1] failures=0" "$LOG"; then
    echo "[test_asn1_parser] OK: failures=0"
else
    echo "[test_asn1_parser] MISS: failures=0 absent"
    fail=1
fi

# Final PASS line — proves we reached the end of main().
if grep -F -q "[asn1] PASS" "$LOG"; then
    echo "[test_asn1_parser] OK: fixture reached PASS"
else
    echo "[test_asn1_parser] MISS: PASS line absent"
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_asn1_parser] FAIL (qemu rc=$rc)"
    exit 1
fi

echo "[test_asn1_parser] PASS"
