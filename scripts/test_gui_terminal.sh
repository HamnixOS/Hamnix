#!/usr/bin/env bash
# scripts/test_gui_terminal.sh — per-window hamUI terminal I/O routing test.
#
# Verifies that the `hamUId daemon terminalselftest` path correctly:
#   (a) spawns a child hamsh wired to kernel pipes (not the serial console),
#   (b) routes a sentinel command to that window's stdin pipe,
#   (c) pumps the child's stdout into the per-window terminal grid,
#   (d) confirms the sentinel string appears in the grid,
#   (e) tests the focus-switch: a body-click raises the clicked window to
#       topmost, changing which window receives keystrokes.
#
# The test uses `autoflag=5` (`terminalselftest`), which runs the logic
# inline (no physical framebuffer or mouse injection needed) and exits after
# printing "TERM IO PASS" / "TERM IO FAIL <reason>".
#
# QEMU timeout: 120 s (generous for TCG: the test yields ~160 times waiting
# for the child shell to process two commands).

. "$(dirname "$0")/_build_lock.sh"

set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf

echo "[test_gui_terminal] (1/4) Build userland"
bash scripts/build_user.sh >/dev/null
bash scripts/build_modules.sh >/dev/null

echo "[test_gui_terminal] (2/4) Build initramfs"
python3 scripts/build_initramfs.py >/dev/null

echo "[test_gui_terminal] (3/4) Rebuild kernel"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

if [ ! -s build/user/hamUId.elf ]; then
    echo "[test_gui_terminal] FAIL: build/user/hamUId.elf missing/empty"
    exit 1
fi

echo "[test_gui_terminal] (4/4) Boot QEMU + run hamUId daemon terminalselftest"

LOG="$(mktemp)"
trap 'rm -f "$LOG"' EXIT

# The terminalselftest autoflag (5) spawns windows with piped hamsh children,
# writes sentinel commands to their stdin pipes, and pumps their stdout into
# the per-window terminal grid. It then asserts the grid contains the sentinel
# strings and that a body-click focus-switch routes input to the correct pipe.
# The test exits after completion (does not spin in the main present-loop) so
# QEMU exits naturally with rc=0; the bash `timeout` kills it if it hangs.
set +e
(
    sleep 8
    printf 'echo MARK_TERM_BEGIN; hamUId daemon terminalselftest\n'
    sleep 100
) | timeout 120s qemu-system-x86_64 \
    -kernel "$ELF" \
    -smp 2 \
    -vga std \
    -display none \
    -no-reboot \
    -m 256M \
    -serial stdio \
    > "$LOG" 2>&1
rc=$?
set -e

echo "[test_gui_terminal] --- captured serial output (tail 60) ---"
tail -n 60 "$LOG"
echo "[test_gui_terminal] --- end serial output ---"

fail=0

# Kernel panic / trap is always a hard failure.
if grep -aE -q "PANIC|panic:|TRAP:|BUG:" "$LOG"; then
    echo "[test_gui_terminal] FAIL: kernel panic / trap"
    exit 1
fi

# (1) The daemon came up successfully.
if grep -aE -q 'DAEMON up screen=[0-9]+x[0-9]+' "$LOG"; then
    dline="$(grep -aoE 'DAEMON up screen=[0-9]+x[0-9]+' "$LOG" | head -n1)"
    echo "[test_gui_terminal] OK: daemon started: '$dline'"
else
    echo "[test_gui_terminal] FAIL: 'DAEMON up screen=' never appeared"
    fail=1
fi

# (2) Window-0 sentinel confirmed in the terminal grid.
if grep -aq 'TERM IO window0 OK' "$LOG"; then
    echo "[test_gui_terminal] OK: window 0 stdin->stdout->grid routing verified"
else
    echo "[test_gui_terminal] FAIL: 'TERM IO window0 OK' not found"
    fail=1
fi

# (3) Focus-switch via body-click confirmed (or graceful skip if only one
#     window was creatable — e.g. wsys table-full limits).
if grep -aq 'TERM IO focus-switch OK' "$LOG"; then
    echo "[test_gui_terminal] OK: body-click focus switch verified"
elif grep -aq 'TERM IO PASS (single-window)' "$LOG"; then
    echo "[test_gui_terminal] OK: single-window pass (focus-switch skipped)"
else
    echo "[test_gui_terminal] FAIL: 'TERM IO focus-switch OK' not found"
    fail=1
fi

# (4) Window-1 sentinel confirmed (only present in full two-window mode).
if grep -aq 'TERM IO window1 OK' "$LOG"; then
    echo "[test_gui_terminal] OK: window 1 post-focus-switch routing verified"
fi

# (5) Overall PASS marker.
if grep -aq 'TERM IO PASS' "$LOG"; then
    echo "[test_gui_terminal] OK: TERM IO PASS marker present"
else
    # A FAIL marker from the selftest is a hard failure.
    if grep -aq 'TERM IO FAIL' "$LOG"; then
        failmsg="$(grep -ao 'TERM IO FAIL[^\n]*' "$LOG" | head -n1)"
        echo "[test_gui_terminal] FAIL: selftest reported: '$failmsg'"
    else
        echo "[test_gui_terminal] FAIL: 'TERM IO PASS' never appeared"
    fi
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_gui_terminal] FAIL"
    exit 1
fi

echo "[test_gui_terminal] PASS"
