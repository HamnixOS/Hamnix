#!/usr/bin/env bash
# scripts/test_console_quiet.sh — post-interactive console-quiet +
# dmesg-completeness regression.
#
# Two things this test guards, both added to stop kernel diagnostic
# chatter from corrupting the line the user is editing at the hamsh
# prompt (see drivers/input/atkbd.ad + drivers/tty/serial/early_8250.ad
# + kernel/printk/printk.ad):
#
#   1. The leftover [atkbd-diag] keyboard-bring-up instrumentation no
#      longer prints on a periodic timer. atkbd_diag_tick() emits ONE
#      boot-time sample (~5 s in) and is then silent unless the
#      ATKBD_DIAG_VERBOSE debug flag is flipped on. So the recurring
#      `[atkbd-diag] irq1_count=... poll_calls=...` flood line must
#      appear AT MOST ONCE in the whole boot console.
#
#   2. Once userland is interactive (the kernel sees the first stdin
#      read), the console-loglevel gate tightens: low-severity kernel
#      printk (INFO/DEBUG) goes to the printk ring buffer only, not
#      the live console. EVERY message still lands in the ring, so
#      `dmesg` (which snapshots the whole 64 KiB ring) still replays
#      the complete kernel log — including the suppressed messages.
#
# Strategy: boot with the default /init (hamsh), let it reach the
# interactive prompt, sit IDLE for ~7 s (long enough for the old
# 5 s atkbd-diag timer to have fired multiple times), then run
# `dmesg` and `exit`. We split the captured console at the unique
# `CONSOLE_QUIET_PROBE` sentinel:
#
#   * BEFORE the sentinel  -> the live console (boot + idle window).
#     The recurring atkbd-diag line must appear <= 1 time here.
#   * dmesg output         -> must replay kernel log content, proving
#     the ring buffer is intact and reachable.

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf

echo "[test_console_quiet] (1/3) Build userland (hamsh + dmesg)"
bash scripts/build_user.sh >/dev/null

echo "[test_console_quiet] (2/3) Build default initramfs (/init = shim)"
python3 scripts/build_initramfs.py >/dev/null

echo "[test_console_quiet] (3/3) Rebuild kernel + boot QEMU"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal init/main.ad -o "$ELF" >/dev/null

LOG=$(mktemp)
trap 'rm -f "$LOG"' EXIT

set +e
(
    # Reach the interactive prompt, then sit idle long enough that the
    # old periodic [atkbd-diag] timer (~5 s) would have fired several
    # times if it were still running.
    sleep 9
    # Sentinel marks the boundary between the idle-window console and
    # the dmesg replay. Echoed by the shell to stdout — userland
    # output is always console-visible (console_force_mirror).
    printf 'echo CONSOLE_QUIET_PROBE\n'
    sleep 1
    printf 'dmesg\n'
    sleep 3
    printf 'exit\n'
    sleep 1
) | timeout 30s qemu-system-x86_64 \
    -kernel "$ELF" \
    -smp 2 -nographic -no-reboot -m 256M -monitor none -serial stdio \
    > "$LOG" 2>&1
set -e

echo "[test_console_quiet] --- captured output ---"
cat "$LOG"
echo "[test_console_quiet] --- end output ---"

fail=0

# Sanity: we actually reached the interactive prompt.
if grep -F -q "hamsh$" "$LOG"; then
    echo "[test_console_quiet] OK: interactive hamsh prompt reached"
else
    echo "[test_console_quiet] MISS: never reached the hamsh prompt"
    fail=1
fi

# Sanity: the sentinel echoed back (shell stayed responsive, and
# userland stdout still reaches the console post-interactive).
if grep -F -q "CONSOLE_QUIET_PROBE" "$LOG"; then
    echo "[test_console_quiet] OK: shell responsive, stdout reaches console"
else
    echo "[test_console_quiet] MISS: sentinel not echoed"
    fail=1
fi

# --- (1) atkbd-diag flood is silenced -------------------------------
# Split the console at the sentinel: everything before it is the live
# boot + idle-window console (dmesg has not run yet). The recurring
# poll line is identified by the `poll_calls=` substring, which the
# one-shot controller-init transcript does NOT contain. It must show
# up at most once (the single boot-time sample).
PRE=$(sed -n '1,/CONSOLE_QUIET_PROBE/p' "$LOG")
DIAG_HITS=$(printf '%s\n' "$PRE" | grep -c "atkbd-diag] irq1_count=" || true)
if [ "$DIAG_HITS" -le 1 ]; then
    echo "[test_console_quiet] OK: atkbd-diag flood silenced (live hits=$DIAG_HITS)"
else
    echo "[test_console_quiet] MISS: atkbd-diag still floods console (hits=$DIAG_HITS)"
    fail=1
fi

# --- (2) dmesg replays the full kernel log --------------------------
# The early-boot banner "Hamnix kernel booting" is pushed into the
# printk ring on every boot. It shows up ONCE on the live boot
# console; if `dmesg` replays the ring it shows up a SECOND time.
# Requiring >= 2 occurrences therefore proves dmesg actually drained
# the ring buffer (a one-occurrence log would mean dmesg produced
# nothing). The ring carries every message — including the INFO
# traffic the console-loglevel gate suppressed post-interactive — so
# a working dmesg means the complete kernel log stays retrievable.
BANNER_HITS=$(grep -c "Hamnix kernel booting" "$LOG" || true)
if [ "$BANNER_HITS" -ge 2 ]; then
    echo "[test_console_quiet] OK: dmesg replays the kernel log ring buffer"
else
    echo "[test_console_quiet] MISS: kernel log not retrievable via dmesg (banner hits=$BANNER_HITS)"
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_console_quiet] FAIL"
    exit 1
fi

echo "[test_console_quiet] PASS"
