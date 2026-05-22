#!/usr/bin/env bash
# scripts/test_xz.sh — lib/xz/xz.ad `.xz` (LZMA2 / LZMA) decompressor
# regression.
#
# Regenerates tests/test_xz_fixtures.ad (real `xz`-compressed payloads,
# see scripts/gen_xz_fixture.py), builds tests/test_xz.ad as a userland
# x86_64 ELF, plants it at /bin/test_xz in the cpio initramfs, boots
# QEMU + hamsh, runs the binary, and greps the serial log for the
# [xz] PASS banner.
#
# Covers: a small literal-heavy stream, a match-copy-heavy stream, an
# RFC822 Packages-stanza-shaped stream (the apt use case), and a
# 96 KiB MULTI-BLOCK stream (xz --block-size forces several xz blocks
# + many LZMA2 chunks). Plus negative cases: bad magic, truncated
# input, and an undersized dst buffer all produce rc<0.
#
# PASS criterion: "[xz] failures=0" AND "[xz] PASS" both present.
# Shape mirrors scripts/test_inflate.sh.

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf
TEST_ELF=build/user/test_xz.elf
FIXTURES=tests/test_xz_fixtures.ad

if ! command -v xz >/dev/null 2>&1; then
    echo "[test_xz] FAIL: host 'xz' binary not found (needed to build fixtures)"
    exit 1
fi

echo "[test_xz] (1/6) Generate xz fixtures -> $FIXTURES"
python3 scripts/gen_xz_fixture.py "$FIXTURES"

echo "[test_xz] (2/6) Build userland (hamsh + coreutils)"
bash scripts/build_user.sh >/dev/null
bash scripts/build_modules.sh >/dev/null

echo "[test_xz] (3/6) Build tests/test_xz.ad -> $TEST_ELF"
python3 -m compiler.adder compile \
    --target=x86_64-adder-user \
    tests/test_xz.ad \
    -o "$TEST_ELF" >/dev/null

echo "[test_xz] (4/6) Plant /init = hamsh + /bin/test_xz in cpio"
INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py >/dev/null

echo "[test_xz] (5/6) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

echo "[test_xz] (6/6) Boot QEMU + drive /bin/test_xz via hamsh"
LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null' EXIT

set +e
(
    sleep 3
    printf '/bin/test_xz\n'
    sleep 4
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

echo "[test_xz] --- captured output ---"
cat "$LOG"
echo "[test_xz] --- end output ---"

fail=0

if grep -F -q "[xz] start" "$LOG"; then
    echo "[test_xz] OK: fixture ran"
else
    echo "[test_xz] MISS: fixture banner missing"
    fail=1
fi

if grep -F -q "[xz] FAIL:" "$LOG"; then
    echo "[test_xz] MISS: per-assertion FAIL line(s) present:"
    grep -F "[xz] FAIL:" "$LOG" | sed 's/^/  /'
    fail=1
else
    echo "[test_xz] OK: no per-assertion FAIL lines"
fi

if grep -F -q "[xz] failures=0" "$LOG"; then
    echo "[test_xz] OK: failures=0"
else
    echo "[test_xz] MISS: failures=0 absent"
    fail=1
fi

if grep -F -q "[xz] PASS" "$LOG"; then
    echo "[test_xz] OK: fixture reached PASS"
else
    echo "[test_xz] MISS: PASS line absent"
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_xz] FAIL (qemu rc=$rc)"
    exit 1
fi

echo "[test_xz] PASS"
