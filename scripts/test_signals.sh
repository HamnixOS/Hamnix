#!/usr/bin/env bash
# scripts/test_signals.sh - M16.39 verification.
#
# Boot hamsh, start /cat with no args (drains stdin via the UART
# RX FIFO and blocks), send a Ctrl-C byte (0x03), and verify:
#
#   - /cat exits with code 130 (= 128 + SIGINT/2) — the kernel's
#     default-disposition signal path fired.
#   - hamsh's sys_waitpid returns and the prompt reappears — the
#     shell didn't die alongside the child.
#
# After the child is killed we send `exit` so hamsh returns cleanly
# and the box halts, keeping the boot log a manageable size.

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-vmlinux.elf
HAMSH_ELF=build/user/hamsh.elf

echo "[test_signals] (1/4) Build userland"
bash scripts/build_user.sh
bash scripts/build_modules.sh

echo "[test_signals] (2/4) Swap /init = $HAMSH_ELF"
INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py

echo "[test_signals] (3/4) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF"

echo "[test_signals] (4/4) Boot QEMU; /cat then Ctrl-C"
LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null' EXIT

set +e
(
    sleep 3
    printf '/cat\n'                            # /cat blocks reading stdin
    sleep 1
    printf '\x03'                              # Ctrl-C → SIGINT to /cat
    sleep 1
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

echo "[test_signals] --- captured output ---"
cat "$LOG"
echo "[test_signals] --- end output ---"

fail=0
# /cat is pid 2 (hamsh is pid 1). SIGINT default exit code is 128+2=130.
if grep -E -q "task: pid 2 exited \(code=130\)" "$LOG"; then
    echo "[test_signals] OK: /cat killed by SIGINT (exit code 130)"
else
    echo "[test_signals] MISS: 'task: pid 2 exited (code=130)' not found"
    fail=1
fi
# hamsh ('[hamsh] bye.') still ran after the child died — meaning
# SIGINT was correctly scoped to non-pid-1 tasks.
if grep -F -q "[hamsh] bye." "$LOG"; then
    echo "[test_signals] OK: hamsh survived the Ctrl-C"
else
    echo "[test_signals] MISS: hamsh didn't reach its exit path"
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_signals] FAIL (qemu rc=$rc)"
    exit 1
fi
echo "[test_signals] PASS"
