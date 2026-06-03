#!/usr/bin/env bash
# scripts/test_console_cup.sh — CSI absolute cursor-position (CUP) test
# for the two text consoles.
#
# Goal:
#   Prove the ESC[<row>;<col>H / ESC[<row>;<col>f cursor-position escape
#   sequence — the backbone of every full-screen TUI (vi, less, top,
#   ncurses apps, the installer) — lands the cursor on the requested
#   1-based cell, clamped into the grid, on BOTH text consoles:
#     * drivers/video/console/vga_text.ad  (legacy 80x25 VGA text)
#     * drivers/video/console/fb_text.ad   (EFI/GOP framebuffer)
#
#   Before this fix both parsers carried a single parameter accumulator
#   and discarded the ';' separator, so ESC[<row>;<col>H always homed to
#   (0,0) — the column was silently dropped. The self-tests below drive
#   the REAL fb_putc / vga_putc CSI code path and assert fb_row/fb_col
#   and vga_row/vga_col (plus the VGA hardware-cursor CRTC cell).
#
# The self-tests are chained off vga_init(), which runs on every boot
# (QEMU always exposes the VGA text buffer), so no init/main.ad edit is
# needed. They print:
#     [vga-cup] PASS   and   [fb-cup] PASS
# on success.

. "$(dirname "$0")/_build_lock.sh"

set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf

echo "[test_console_cup] (1/3) Build userland + modules + initramfs"
if [ ! -f build/user/init.elf ]; then
    bash scripts/build_user.sh >/dev/null
    bash scripts/build_modules.sh >/dev/null
fi
INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null

echo "[test_console_cup] (2/3) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

echo "[test_console_cup] (3/3) Boot QEMU and capture the self-test markers"
LOG=$(mktemp)
trap 'rm -f "$LOG"' EXIT

set +e
timeout 30s qemu-system-x86_64 \
    -kernel "$ELF" \
    -smp 2 \
    -nographic \
    -no-reboot \
    -m 256M \
    -monitor none \
    -serial stdio \
    > "$LOG" 2>&1 < /dev/null
rc=$?
set -e

echo "[test_console_cup] --- captured cup lines ---"
grep -E "vga-cup|fb-cup" "$LOG" || true
echo "[test_console_cup] --- end ---"

fail=0

if grep -E -q "\[vga-cup\] FAIL" "$LOG"; then
    echo "[test_console_cup] FAIL: vga CUP assertion(s) failed"
    fail=1
fi
if grep -E -q "\[fb-cup\] FAIL" "$LOG"; then
    echo "[test_console_cup] FAIL: fb CUP assertion(s) failed"
    fail=1
fi

if grep -F -q "[vga-cup] PASS" "$LOG"; then
    echo "[test_console_cup] OK: [vga-cup] PASS present"
else
    echo "[test_console_cup] MISS: [vga-cup] PASS absent"
    fail=1
fi
if grep -F -q "[fb-cup] PASS" "$LOG"; then
    echo "[test_console_cup] OK: [fb-cup] PASS present"
else
    echo "[test_console_cup] MISS: [fb-cup] PASS absent"
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_console_cup] FAIL (qemu rc=$rc)"
    echo "[test_console_cup] --- full log tail ---"
    tail -n 60 "$LOG"
    exit 1
fi

echo "[test_console_cup] PASS"
exit 0
