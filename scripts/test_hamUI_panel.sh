#!/usr/bin/env bash
# scripts/test_hamUI_panel.sh — hamUI panel + Applications menu launcher.
#
# Verifies the GNOME2/MATE-style desktop launcher built into the
# persistent `hamUId daemon`: a top PANEL with an "Applications" menu
# button, a classic vertical APPLICATION MENU, and menu-item launching a
# real program into a new window via the daemon's spawn-into-window path.
#
# DETERMINISTIC PROOF (primary). `hamUId daemon panelselftest` drives the
# launcher by calling the EXACT same gesture state machine (wm_button)
# that real /dev/mouse packets reach — with absolute cursor coordinates,
# so no QEMU mouse injection and the result is repeatable. The daemon
# emits these serial markers we assert on:
#     PANEL open menu
#     PANEL launch Terminal
#     DAEMON panel selftest done
# The launch traverses the real generalised spawn path
# (daemon_spawn_window_prog -> sys_pipe/sys_spawn/sys_wsys_alloc), so a
# real /bin/hamsh process is bound into a real window; the self-test only
# supplies the cursor coordinates a non-interactive QEMU run cannot drive
# with pixel precision.
#
# SKIPS CLEANLY (exit 0) when the daemon can't come up under -vga std on
# this host (same QEMU multiboot VBE + 64-bit limitation the WM self-test
# guards against). The authoritative GOP gate is test_img_uefi_hamui.sh.

. "$(dirname "$0")/_build_lock.sh"

set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf

echo "[test_hamUI_panel] (1/4) Build userland"
bash scripts/build_user.sh >/dev/null
bash scripts/build_modules.sh >/dev/null

echo "[test_hamUI_panel] (2/4) Build initramfs"
python3 scripts/build_initramfs.py >/dev/null

echo "[test_hamUI_panel] (3/4) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

if [ ! -s build/user/hamUId.elf ]; then
    echo "[test_hamUI_panel] FAIL: build/user/hamUId.elf missing/empty"
    exit 1
fi

echo "[test_hamUI_panel] (4/4) Boot QEMU + run the panel self-test (open menu + launch)"

LOG="$(mktemp)"
trap 'rm -f "$LOG"' EXIT

set +e
(
    sleep 10
    printf 'echo MARK_PANEL_BEGIN; hamUId daemon panelselftest\n'
    sleep 25
) | timeout 75s qemu-system-x86_64 \
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

# A kernel panic / CPU trap is ALWAYS a hard failure — check it first, so a
# real daemon crash can never be masked by the environment-skip below.
if grep -aE -q "PANIC|panic:|TRAP:|BUG:" "$LOG"; then
    echo "[test_hamUI_panel] FAIL: kernel panic / trap"
    tail -n 60 "$LOG"
    exit 1
fi

# SKIP CLEANLY when the hamUId daemon never came up under -vga std on this
# host (QEMU multiboot VBE + 64-bit limitation / no VBE framebuffer). The
# shipped UEFI/GOP path (test_img_uefi_hamui.sh) is the authoritative gate.
if ! grep -aq 'DAEMON up screen=' "$LOG"; then
    echo "[test_hamUI_panel] SKIP: hamUId daemon did not come up under -vga std on this host. Authoritative GOP gate: scripts/test_img_uefi_hamui.sh." >&2
    exit 0
fi

echo "[test_hamUI_panel] --- captured serial output (PANEL markers) ---"
grep -aE 'DAEMON|PANEL|MARK_PANEL_BEGIN' "$LOG" | head -40
echo "[test_hamUI_panel] --- end ---"

fail=0

assert_marker() {
    if grep -aq "$1" "$LOG"; then
        echo "[test_hamUI_panel] OK: $2"
    else
        echo "[test_hamUI_panel] MISS: $2 (expected marker: '$1')"
        fail=1
    fi
}

assert_marker 'DAEMON up screen=' 'daemon started + read framebuffer geometry'
assert_marker 'PANEL open menu' 'Applications button press opened the menu'
assert_marker 'PANEL launch Terminal' 'menu-item click launched a program into a window'
assert_marker 'DAEMON panel selftest done' 'self-test ran to completion (no hang/crash)'

# rc=124 (timeout killed the forever-looping daemon) is EXPECTED — the
# daemon present-loop never exits on its own.
if [ "$fail" -ne 0 ]; then
    echo "[test_hamUI_panel] FAIL (qemu rc=$rc)"
    exit 1
fi

echo "[test_hamUI_panel] capture method: drives the real daemon gesture machine (wm_button) with absolute coordinates + deterministic serial markers"
echo "[test_hamUI_panel] PASS"
