#!/usr/bin/env bash
# scripts/test_wsys_input.sh — hamUI per-window INPUT EVENT surface test.
#
# Verifies the structured pointer / key event files added to the kernel
# window server (sys/src/9/port/devwsys.ad + sys/src/9/port/namec.ad):
#
#   /dev/wsys/<N>/pointer  "<type> <x> <y> <buttons> <dz>\n"  routed ptr
#   /dev/wsys/<N>/keys      "<type> <code>\n"                  focused keys
#
# Reads BLOCK on a per-wid wait queue (event-driven; no poll-yield) and
# wake when an event is enqueued. The compositor (user/hamUId.ad) is the
# producer in production; here a single-process userland fixture
# (/bin/test_wsys_input) writes an event then reads it back, asserting the
# exact bytes round-trip through the kernel ring + namec dispatch.
#
# All assertions run inside the fixture (driven by syscalls), so only ONE
# command is typed into hamsh — robust to serial-echo corruption under
# concurrent-agent host load.
#
# Pipeline mirrors scripts/test_wsys_damage.sh.

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf
TEST_ELF=build/user/test_wsys_input.elf

echo "[test_wsys_input] (1/5) Build userland"
bash scripts/build_user.sh >/dev/null
bash scripts/build_modules.sh >/dev/null

echo "[test_wsys_input] (2/5) Build tests/test_wsys_input.ad -> $TEST_ELF"
python3 -m compiler.adder compile \
    --target=x86_64-adder-user \
    tests/test_wsys_input.ad \
    -o "$TEST_ELF" >/dev/null

echo "[test_wsys_input] (3/5) Plant /init = hamsh + /bin/test_wsys_input"
INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py >/dev/null

echo "[test_wsys_input] (4/5) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

echo "[test_wsys_input] (5/5) Boot QEMU + run the fixture via hamsh"
LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null' EXIT

set +e
(
    sleep 8
    printf '/bin/test_wsys_input\n'
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

echo "[test_wsys_input] --- captured output ---"
cat "$LOG"
echo "[test_wsys_input] --- end output ---"

fail=0

if grep -F -q "[test_wsys_input] start" "$LOG"; then
    echo "[test_wsys_input] OK: fixture ran"
else
    echo "[test_wsys_input] MISS: fixture banner missing"
    fail=1
fi

for marker in pointer_write_ok pointer_read_ok pointer_recompact_ok \
              keys_write_ok keys_read_ok; do
    if grep -F -q "[test_wsys_input] ${marker}=1" "$LOG"; then
        echo "[test_wsys_input] OK: ${marker}"
    else
        echo "[test_wsys_input] MISS: ${marker}"
        fail=1
    fi
done

if grep -F -q "[test_wsys_input] PASS" "$LOG"; then
    echo "[test_wsys_input] OK: fixture overall PASS"
else
    echo "[test_wsys_input] MISS: fixture FAIL or did not complete"
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_wsys_input] FAIL (qemu rc=$rc)"
    exit 1
fi

echo "[test_wsys_input] PASS"
