#!/usr/bin/env bash
# scripts/test_inflate.sh — streaming DEFLATE / gzip inflater (V0)
# regression.
#
# Builds tests/test_inflate.ad as a userland x86_64 ELF, plants it at
# /bin/test_inflate in the cpio initramfs, boots QEMU + hamsh, runs
# the binary, and greps the serial log for [inflate] PASS.
#
# Covers all three DEFLATE block types (stored / fixed-Huffman /
# dynamic-Huffman), LZ77 backreference copy, the gzip wrapper +
# CRC32 trailer check, and streaming partial-input feed-resume
# behavior. Plus negative cases: corrupted-CRC trailer and bad
# gzip magic both produce rc<0.
#
# PASS criterion: "[inflate] failures=0" AND "[inflate] PASS" both
# present in the serial log. Shape mirrors scripts/test_asn1_parser.sh.

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-vmlinux.elf
HAMSH_ELF=build/user/hamsh.elf
TEST_ELF=build/user/test_inflate.elf

echo "[test_inflate] (1/5) Build userland (hamsh + coreutils)"
bash scripts/build_user.sh >/dev/null
bash scripts/build_modules.sh >/dev/null

echo "[test_inflate] (2/5) Build tests/test_inflate.ad -> $TEST_ELF"
python3 -m compiler.adder compile \
    --target=x86_64-adder-user \
    tests/test_inflate.ad \
    -o "$TEST_ELF" >/dev/null

echo "[test_inflate] (3/5) Plant /init = hamsh + /bin/test_inflate in cpio"
INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py >/dev/null

echo "[test_inflate] (4/5) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

echo "[test_inflate] (5/5) Boot QEMU + drive /bin/test_inflate via hamsh"
LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null' EXIT

set +e
(
    sleep 3
    printf '/bin/test_inflate\n'
    sleep 3
    printf 'exit\n'
    sleep 1
) | timeout 30s qemu-system-x86_64 \
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

echo "[test_inflate] --- captured output ---"
cat "$LOG"
echo "[test_inflate] --- end output ---"

fail=0

if grep -F -q "[inflate] start" "$LOG"; then
    echo "[test_inflate] OK: fixture ran"
else
    echo "[test_inflate] MISS: fixture banner missing"
    fail=1
fi

if grep -F -q "[inflate] FAIL:" "$LOG"; then
    echo "[test_inflate] MISS: per-assertion FAIL line(s) present:"
    grep -F "[inflate] FAIL:" "$LOG" | sed 's/^/  /'
    fail=1
else
    echo "[test_inflate] OK: no per-assertion FAIL lines"
fi

if grep -F -q "[inflate] failures=0" "$LOG"; then
    echo "[test_inflate] OK: failures=0"
else
    echo "[test_inflate] MISS: failures=0 absent"
    fail=1
fi

if grep -F -q "[inflate] PASS" "$LOG"; then
    echo "[test_inflate] OK: fixture reached PASS"
else
    echo "[test_inflate] MISS: PASS line absent"
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_inflate] FAIL (qemu rc=$rc)"
    exit 1
fi

echo "[test_inflate] PASS"
