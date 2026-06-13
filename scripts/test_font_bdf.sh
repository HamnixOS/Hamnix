#!/usr/bin/env bash
# scripts/test_font_bdf.sh — Phase 4d BDF parser roundtrip.
#
# Builds tests/test_font_bdf.ad, lands it as /bin/test_font_bdf in the
# initramfs, boots a small QEMU image, drives the fixture from hamsh
# and asserts the "test_font_bdf: OK" sentinel on the serial console.
# Pure unit test for lib/font_bdf.ad — no DE / hamUId / framebuffer
# touched.

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf
TEST_ELF=build/user/test_font_bdf.elf

echo "[test_font_bdf] (1/4) Build userland"
bash scripts/build_user.sh >/dev/null
bash scripts/build_modules.sh >/dev/null

echo "[test_font_bdf] (2/4) Build tests/test_font_bdf.ad -> $TEST_ELF"
python3 -m compiler.adder compile \
    --target=x86_64-adder-user \
    tests/test_font_bdf.ad \
    -o "$TEST_ELF" >/dev/null

echo "[test_font_bdf] (3/4) Plant /init = hamsh, rebuild kernel"
INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py >/dev/null
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

echo "[test_font_bdf] (4/4) Boot QEMU + drive fixture from hamsh"
LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null' EXIT

set +e
(
    # feedback_serial_test_first_cmd_dropped.md — freshly-booted hamsh
    # silently drops the first one or two serial command lines; re-send
    # the invocation a few times until its OK marker appears.
    sleep 4
    printf '/bin/test_font_bdf\n'
    sleep 2
    printf '/bin/test_font_bdf\n'
    sleep 3
    printf '/bin/test_font_bdf\n'
    sleep 3
    printf 'echo POST_BDF_OK\n'
    sleep 1
    printf 'echo POST_BDF_OK\n'
    sleep 2
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

echo "[test_font_bdf] --- captured output ---"
cat "$LOG"
echo "[test_font_bdf] --- end output ---"

fail=0
if grep -F -q "test_font_bdf: OK" "$LOG"; then
    echo "[test_font_bdf] OK: BDF parser roundtrip"
else
    echo "[test_font_bdf] MISS: 'test_font_bdf: OK' absent"
    fail=1
fi
if grep -F -q "POST_BDF_OK" "$LOG"; then
    echo "[test_font_bdf] OK: hamsh still responsive after fixture"
else
    echo "[test_font_bdf] MISS: hamsh did not re-prompt"
    fail=1
fi

if [ $fail -ne 0 ]; then
    echo "[test_font_bdf] FAIL"
    exit 1
fi

echo "[test_font_bdf] PASS"
