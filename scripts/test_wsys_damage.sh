#!/usr/bin/env bash
# scripts/test_wsys_damage.sh — hamUI compositor hot-path regression.
#
# Verifies the ADDITIVE per-window damage / dirty-rect interface added to
# the kernel window server (sys/src/9/port/devwsys.ad):
#
#   /dev/wsys/<N>/serial   ->  "<serial>\n"  monotonic per-window gen
#   /dev/wsys/damage       ->  "<wid> <serial> <dx0> <dy0> <dx1> <dy1>\n"
#   write to .../serial     =  ACK -> consume that window's dirty rect
#
# plus the draw-listing render cache (a draw read at an unchanged serial
# reuses the cached bytes instead of re-sorting + re-serialising).
#
# All assertions run inside a userland fixture (/bin/test_wsys_damage)
# that drives the files via syscalls — only ONE command is typed into
# hamsh, so the test is robust to the serial-echo corruption that flakes
# the interactive draw tests under concurrent-agent host load.
#
# Pipeline mirrors scripts/test_hamUI_phase1.sh.

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf
TEST_ELF=build/user/test_wsys_damage.elf

echo "[test_wsys_damage] (1/5) Build userland"
bash scripts/build_user.sh >/dev/null
bash scripts/build_modules.sh >/dev/null

echo "[test_wsys_damage] (2/5) Build tests/test_wsys_damage.ad -> $TEST_ELF"
python3 -m compiler.adder compile \
    --target=x86_64-adder-user \
    tests/test_wsys_damage.ad \
    -o "$TEST_ELF" >/dev/null

echo "[test_wsys_damage] (3/5) Plant /init = hamsh + /bin/test_wsys_damage"
INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py >/dev/null

echo "[test_wsys_damage] (4/5) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

echo "[test_wsys_damage] (5/5) Boot QEMU + run the fixture via hamsh"
LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null' EXIT

set +e
(
    sleep 8
    printf '/bin/test_wsys_damage\n'
    sleep 6
    printf 'exit\n'
    sleep 2
) | timeout 60s qemu-system-x86_64 \
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

echo "[test_wsys_damage] --- captured output ---"
cat "$LOG"
echo "[test_wsys_damage] --- end output ---"

fail=0

if grep -F -q "[test_wsys_damage] start" "$LOG"; then
    echo "[test_wsys_damage] OK: fixture ran"
else
    echo "[test_wsys_damage] MISS: fixture banner missing"
    fail=1
fi

for marker in serial_read_ok damage_read_ok serial_bumped_ok \
              dirty_rect_ok serial_stable_ok listing_cache_ok \
              ack_clears_rect_ok; do
    if grep -F -q "[test_wsys_damage] ${marker}=1" "$LOG"; then
        echo "[test_wsys_damage] OK: ${marker}"
    else
        echo "[test_wsys_damage] MISS: ${marker}"
        fail=1
    fi
done

if grep -F -q "[test_wsys_damage] PASS" "$LOG"; then
    echo "[test_wsys_damage] OK: fixture overall PASS"
else
    echo "[test_wsys_damage] MISS: fixture FAIL or did not complete"
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_wsys_damage] FAIL (qemu rc=$rc)"
    exit 1
fi

echo "[test_wsys_damage] PASS"
