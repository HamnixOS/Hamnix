#!/usr/bin/env bash
# scripts/test_console_input_stress.sh — console RX no-drop regression.
#
# Regression guard for the serial RX character-drop bug: the 16550
# UART hardware RX FIFO is only 16 bytes. Before COM1 RX was made
# interrupt-driven, the FIFO was drained solely by the 100 Hz timer
# ISR, so a burst of serial input longer than 16 bytes — exactly
# what a `printf` from a test driver or a terminal paste produces —
# overflowed the FIFO between timer ticks and silently dropped the
# leading characters. `busybox ls /etc` arrived at the shell as
# `ybox ls /etc`, `sybox`, or nothing at all.
#
# The fix routes COM1's IRQ 4 to a handler that drains the hardware
# FIFO into the 256-byte software ring the instant a byte arrives,
# so input is captured independent of the consumer's timing. This
# test proves it: it sends a ~100-byte command line in a SINGLE
# `printf` with NO inter-character sleeps — far over the 16-byte
# hardware FIFO — and asserts the whole unique payload echoes back
# from hamsh intact. Deliberately NOT spaced out with sleeps: the
# burst is the test.
#
# Repeated several times in one boot to shake out any residual
# timing flake.

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-vmlinux.elf
HAMSH_ELF=build/user/hamsh.elf

echo "[test_console_input_stress] (1/4) Build userland (incl. hamsh)"
bash scripts/build_user.sh
bash scripts/build_modules.sh

echo "[test_console_input_stress] (2/4) Swap /init = hamsh in initramfs"
INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py

echo "[test_console_input_stress] (3/4) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF"

echo "[test_console_input_stress] (4/4) Boot QEMU + burst-feed the shell"
LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null' EXIT

# A ~95-char payload after `echo ` — well past the 16-byte 16550 RX
# FIFO. Each round uses a distinct marker so a partial / corrupted
# line cannot accidentally match a different round's output. The
# whole `echo ...\n` line goes out in ONE printf: a single burst,
# no inter-byte delay, the way a paste or fast typist hits it.
PAYLOAD_A="ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJKLMNOPQRST"
ROUND1="STRESS1_${PAYLOAD_A}_END1"
ROUND2="STRESS2_${PAYLOAD_A}_END2"
ROUND3="STRESS3_${PAYLOAD_A}_END3"
ROUND4="STRESS4_${PAYLOAD_A}_END4"

set +e
(
    # Let the kernel finish boot + reach the shell prompt. This sleep
    # is for the PROMPT, not for the RX path — the interrupt-driven
    # RX captures bytes regardless, but there is no point echoing
    # before hamsh exists to echo them.
    sleep 4
    # Each command line is emitted in a single printf with no pause —
    # the entire >16-byte burst lands in the 16550 at once.
    printf 'echo %s\n' "$ROUND1"
    sleep 1
    printf 'echo %s\n' "$ROUND2"
    sleep 1
    printf 'echo %s\n' "$ROUND3"
    sleep 1
    printf 'echo %s\n' "$ROUND4"
    sleep 1
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

echo "[test_console_input_stress] --- captured output (last 80 lines) ---"
tail -n 80 "$LOG"
echo "[test_console_input_stress] --- end output ---"

fail=0

# The interrupt-driven RX wiring must be live.
if grep -F -q "COM1 UART RX is interrupt-driven" "$LOG"; then
    echo "[test_console_input_stress] OK: UART RX IRQ wired"
else
    echo "[test_console_input_stress] FAIL: UART RX IRQ never wired"
    fail=1
fi

# Every burst must have echoed back byte-for-byte intact.
for round in "$ROUND1" "$ROUND2" "$ROUND3" "$ROUND4"; do
    if grep -F -q "$round" "$LOG"; then
        echo "[test_console_input_stress] OK: burst intact -> $round"
    else
        echo "[test_console_input_stress] FAIL: burst dropped/garbled -> $round"
        fail=1
    fi
done

if grep -F -q "TRAP: vector" "$LOG"; then
    echo "[test_console_input_stress] DIAG: kernel reported a CPU exception"
    grep -F "TRAP: vector" "$LOG" | head -5 || true
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_console_input_stress] FAIL (qemu rc=$rc)"
    exit 1
fi

echo "[test_console_input_stress] PASS -- no console-input bytes dropped"
