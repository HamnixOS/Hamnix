#!/usr/bin/env bash
# scripts/test_vk_window.sh — GPU track #183, Phase 2 (native software
# rasterizer slice): native Vulkan output INTO a real desktop window.
#
# This proves the native lib/vk software rasterizer can render the CONTENT
# of a normal hamUI window — composited and presented by the desktop daemon
# (hamUId) at the window's on-screen position, in z-order, like any other
# window — instead of vkQueuePresent taking over the whole /dev/fb screen.
#
# HOW IT WORKS (the faithful kernel/userland split)
#   lib/vk is a KERNEL library (kmalloc/printk/fb_text backed), unreachable
#   from a userland binary. So the Vulkan RENDER runs in the kernel
#   (lib/vk/vk_window_demo.ad), driven once per frame by a thin syscall
#   (SYS_VK_WINDOW_FRAME=312, hostowner-only). The kernel renders a rotating
#   triangle into an offscreen R8G8B8A8 image and PRESENTS it via
#   vk_present_to_window() into the window's draw FILE SURFACE
#   (/dev/wsys/<wid>/draw/vk/fb) — the SAME per-window draw surface a normal
#   app writes RGBA into. The userland desktop COMPOSITE runs in hamUId,
#   which reads that draw layer and composites the window at its on-screen
#   rect through its normal daemon_present() path to /dev/fb.
#
# The test drives the daemon's `vkwindowselftest` mode over hamsh's stdin,
# gated on the "[hamsh] M16.35 shell ready" readiness marker (NOT a fixed
# sleep — boot timing on TCG varies). The daemon needs a live /dev/fb +
# /dev/mouse, so QEMU runs with a real VGA framebuffer (-vga std), serial
# on stdio, and no graphical window (-display none). The selftest does NOT
# spin the main present loop — it runs the assertions inline and exits.
#
# UNFORGEABLE assertions (the daemon prints these as "[vk-window] ..." lines;
# every value is read back from the COMPOSITED frame via daemon_pixel — the
# exact byte written to /dev/fb at that screen pixel):
#   * outside the window rect the screen shows the desktop BACKDROP
#     -> the window is WINDOWED, not a full-screen takeover (z-order works)
#   * inside the window body the screen shows VULKAN content (not backdrop,
#     not the plain body fill) -> the rasterizer output reached the surface
#   * frame 0 vs frame 6 differ at a moving pixel -> LIVE animation, not a
#     static blit
#
# Pass marker:  [vk-window] PASS
# Fail markers: [vk-window] FAIL <reason>

. "$(dirname "$0")/_build_lock.sh"
# The kernel is a higher-half elf64 image; qemu's `-kernel` rejects it.
# _kernel_iso.sh installs a build/binshim/qemu-system-x86_64 wrapper
# (prepended to PATH) that transparently wraps the ELF in a GRUB ISO and
# boots it via -cdrom. So the `-kernel <elf>` below Just Works.
. "$(dirname "$0")/_kernel_iso.sh"

set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf
READY="[hamsh] M16.35 shell ready"
OVERALL_TIMEOUT=160

echo "[test_vk_window] (1/4) Build userland (hamUId, init)"
bash scripts/build_user.sh >/dev/null
bash scripts/build_modules.sh >/dev/null

echo "[test_vk_window] (2/4) Build initramfs"
python3 scripts/build_initramfs.py >/dev/null

echo "[test_vk_window] (3/4) Rebuild kernel"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

if [ ! -s build/user/hamUId.elf ]; then
    echo "[test_vk_window] FAIL: build/user/hamUId.elf missing/empty"
    exit 1
fi

echo "[test_vk_window] (4/4) Boot QEMU + run hamUId daemon vkwindowselftest"

LOG="${VKWIN_LOG:-$(mktemp)}"
trap '[ -z "${VKWIN_LOG:-}" ] && rm -f "$LOG"' EXIT

# --- prompt-aware feeder (mirrors the proven scripts/test_gui_terminal.sh
#     pipe pattern, but adaptive instead of a fixed `sleep 8`). The feeder
#     is the LEFT side of a pipe whose stdout is QEMU's serial stdin. It
#     polls the serial log for hamsh's readiness banner, then a short settle,
#     then writes the daemon command. A trailing sleep keeps the pipe open
#     so QEMU's serial RX stays attached while the inline selftest runs and
#     prints its "[vk-window]" markers. KVM contention can stretch boot well
#     past any fixed delay, so the marker gate (not a timer) decides WHEN to
#     type — feedback_interactive_test_wait_for_prompt. ---
feed() {
    local waited=0 seen=0
    while [ "$waited" -lt "$OVERALL_TIMEOUT" ]; do
        if [ -f "$LOG" ] && grep -aF -q "$READY" "$LOG"; then
            seen=1
            break
        fi
        sleep 1
        waited=$((waited + 1))
    done
    if [ "$seen" -eq 0 ]; then
        echo "[test_vk_window] readiness marker not seen in ${OVERALL_TIMEOUT}s" >&2
        return 0
    fi
    # Settle so hamsh has printed its prompt and is blocked in SYS_READ on
    # stdin before the first byte lands.
    sleep 2
    printf 'echo MARK_VKWIN_BEGIN; hamUId daemon vkwindowselftest\n'
    # Hold the pipe open so QEMU's serial RX stays attached for the whole
    # inline selftest (window spawn + two render frames + composite samples).
    sleep 90
}

# --- QEMU: real VGA framebuffer (-vga std) so /dev/fb exists; serial on
#     stdio; no on-screen window (-display none). The binshim wrapper turns
#     `-kernel <elf64>` into a GRUB -cdrom boot transparently.
set +e
feed | timeout "${OVERALL_TIMEOUT}s" qemu-system-x86_64 \
    -kernel "$ELF" \
    -smp 2 \
    -vga std \
    -display none \
    -no-reboot \
    -m 256M \
    -monitor none \
    -serial stdio \
    > "$LOG" 2>&1
rc=$?
set -e

echo "[test_vk_window] --- captured serial output (vk-window markers) ---"
grep -aE '\[vk-window\]|DAEMON up screen=|MARK_VKWIN_BEGIN' "$LOG" || true
echo "[test_vk_window] --- end markers ---"

fail=0

# Kernel panic / trap is always a hard failure.
if grep -aE -q "PANIC|panic:|TRAP:|BUG:" "$LOG"; then
    echo "[test_vk_window] FAIL: kernel panic / trap"
    tail -n 40 "$LOG"
    exit 1
fi

if [ "$rc" -ne 0 ] && [ "$rc" -ne 124 ]; then
    echo "[test_vk_window] FAIL: qemu exited rc=$rc" >&2
    fail=1
fi

# An explicit internal failure from the selftest is fatal.
if grep -aq '\[vk-window\] FAIL' "$LOG"; then
    failmsg="$(grep -ao '\[vk-window\] FAIL[^\n]*' "$LOG" | head -n1)"
    echo "[test_vk_window] FAIL: selftest reported: '$failmsg'" >&2
    fail=1
fi

# (0) The daemon came up successfully (proves the command was injected and
#     hamUId opened /dev/fb).
if grep -aE -q 'DAEMON up screen=[0-9]+x[0-9]+' "$LOG"; then
    dline="$(grep -aoE 'DAEMON up screen=[0-9]+x[0-9]+' "$LOG" | head -n1)"
    echo "[test_vk_window] OK: daemon started: '$dline'"
else
    echo "[test_vk_window] FAIL: 'DAEMON up screen=' never appeared" >&2
    fail=1
fi

check() {
    local label="$1" needle="$2"
    if grep -aqF "$needle" "$LOG"; then
        echo "[test_vk_window] OK: $label"
    else
        echo "[test_vk_window] FAIL: $label (expected '$needle')" >&2
        fail=1
    fi
}

# (1) Windowed, not full-screen: backdrop visible OUTSIDE the window rect.
check "window is composited (backdrop outside rect)" \
    "[vk-window] OK windowed (backdrop outside window)"
# (2) Vulkan rasterizer output reached the window body.
check "vulkan pixels inside window body" \
    "[vk-window] OK vulkan pixels inside window body"
# (3) Live animation: frame 0 vs frame 6 differ at a moving pixel.
check "animation across distinct frames" \
    "[vk-window] OK animation (frame differs)"

# (4) Overall PASS marker.
if grep -aq '\[vk-window\] PASS' "$LOG"; then
    echo "[test_vk_window] OK: [vk-window] PASS marker present"
else
    echo "[test_vk_window] FAIL: '[vk-window] PASS' never appeared" >&2
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_vk_window] FAIL"
    exit 1
fi

echo "[vk-window] PASS"
echo "[test_vk_window] PASS — native Vulkan software rasterizer rendered a rotating triangle into a real composited hamUI window"
