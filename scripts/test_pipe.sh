#!/usr/bin/env bash
# scripts/test_pipe.sh - M16.38 verification.
#
# Drives hamsh through:
#
#     echo pipe payload | /cat
#     exit
#
# Expects "pipe payload" to appear on serial once — meaning /echo
# wrote to the pipe, the kernel buffered the bytes, cat (running
# with stdin = pipe rfd) drained them and wrote to serial. Proves
# the SYS_PIPE / fd inheritance / blocking-read / writers-closed-EOF
# chain works end to end.

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-vmlinux.elf
HAMSH_ELF=build/user/hamsh.elf

echo "[test_pipe] (1/4) Build userland"
bash scripts/build_user.sh
bash scripts/build_modules.sh

echo "[test_pipe] (2/4) Swap /init = $HAMSH_ELF"
INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py

echo "[test_pipe] (3/4) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF"

echo "[test_pipe] (4/4) Boot QEMU and drive hamsh"
LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null' EXIT

set +e
(
    sleep 3
    printf 'echo pipe payload | cat\n'
    sleep 2
    printf 'exit\n'
    sleep 1
) | timeout 15s qemu-system-x86_64 \
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

echo "[test_pipe] --- captured output ---"
cat "$LOG"
echo "[test_pipe] --- end output ---"

fail=0
# cat's reads and writes interleave with the kernel's exit-log
# printk ("task: pid N exited (code=M)") AND its own chunk
# boundaries (4-byte "pipe", 1-byte " ", 7-byte "payload" hit the
# pipe in separate writes). To assert delivery robustly, strip the
# kernel log line and collapse whitespace so "pipe<...>payload"
# normalizes to "pipe payload" regardless of how the bytes
# interleaved.
cleaned=$(sed 's/task: pid -*[0-9]* exited (code=-*[0-9]*)//g' "$LOG" | tr '\n' ' ' | tr -s ' ')
if echo "$cleaned" | grep -F -q "pipe payload"; then
    echo "[test_pipe] OK: 'pipe payload' delivered via pipe"
else
    echo "[test_pipe] MISS: 'pipe payload' not found"
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_pipe] FAIL (qemu rc=$rc)"
    exit 1
fi
echo "[test_pipe] PASS"
