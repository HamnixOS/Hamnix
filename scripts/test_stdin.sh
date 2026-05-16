#!/usr/bin/env bash
# scripts/test_stdin.sh - verify SYS_READ on fd 0 (stdin) reads from
# the UART.
#
# Swaps /init with build/user/echo.elf, pipes a known string into
# QEMU's serial stdio, and greps the captured serial output for the
# echoed line. Proves the full chain: pipe → host stdin → QEMU serial
# RX → kernel vfs_read(FD_STDIN_MARK, ...) → user-mode SYS_READ →
# user SYS_WRITE back out → host stdout.

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-vmlinux.elf
ECHO_ELF=build/user/stdin_demo.elf
# Keep input short — the 16550 RX FIFO is only 16 bytes and is
# accumulating piped input while the kernel boots (~100 ms), so a
# longer string loses chars off the front. A real shell uses
# interrupt-driven RX with an in-kernel software buffer to dodge
# this; that's a future M16.x milestone.
INPUT="hi"
EXPECT="[/echo] you said: $INPUT"

echo "[test_stdin] Build user binaries"
bash scripts/build_user.sh
bash scripts/build_modules.sh

echo "[test_stdin] Swap /init = build/user/echo.elf"
INIT_ELF="$ECHO_ELF" python3 scripts/build_initramfs.py

echo "[test_stdin] Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF"

echo "[test_stdin] Boot QEMU with piped input"
LOG=$(mktemp)
trap 'rm -f "$LOG"' EXIT
set +e
# Delay the input until AFTER the kernel has booted and echo is
# blocked in SYS_READ. Without this, the chars arrive too early and
# either overflow the 16-byte 16550 RX FIFO during boot prints or
# get dropped on EOF before echo gets to read them. The real fix
# (interrupt-driven RX with a kernel-side buffer) lands in a later
# milestone; for now, just time it right.
(sleep 3; echo "$INPUT"; sleep 2) | timeout 10s qemu-system-x86_64 \
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

echo "[test_stdin] --- captured output ---"
cat "$LOG"
echo "[test_stdin] --- end output ---"

# Restore the default /init so the regular run_x86_bare.sh still works.
INIT_ELF="build/user/init.elf" python3 scripts/build_initramfs.py >/dev/null

if grep -F -q "$EXPECT" "$LOG"; then
    echo "[test_stdin] PASS: '$EXPECT' echoed back"
    exit 0
fi
echo "[test_stdin] FAIL: expected line not found"
echo "[test_stdin] QEMU rc=$rc"
exit 1
