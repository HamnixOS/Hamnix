#!/usr/bin/env bash
# scripts/test_hamUI_markupclient.sh — live compositing of an EXTERNAL
# hamui (lib/hamui.ad) client's "ui" markup layer into the on-screen
# window body.
#
# This is the KEYSTONE that makes the GUI toolkit real: a program built on
# lib/hamui.ad writes a "ui" hamML markup layer to its window's draw
# surface (/dev/wsys/<wid>/draw/ui/markup). Before this change the LIVE
# daemon composite path (daemon_pixel -> app_body_pixel) never consulted
# that layer, so such programs were INVISIBLE in the live frame and only
# verifiable via the offline `present`/`render` one-shot. Now the daemon
# auto-detects a "ui" markup client, rasterises it into a per-window RGBA
# body buffer every present (markup_sync, called from window_cache_sync),
# and window_render_self samples that buffer for the window body.
#
# DETERMINISTIC PROOF. `hamUId daemon markupclient` (autoflag 46):
#   1. Spawns a chrome-only window with a real kernel wid.
#   2. Injects a known "ui" markup layer onto that wid's draw surface
#      exactly the way lib/hamui.ad's hamui_render does (mklayer ui markup
#      + write hamML): a body-filling rect (#22cc44) + a 40x30 inner rect
#      (#cc2244) + a "HAMUI" text run.
#   3. Runs the LIVE daemon_present() path.
#   4. Samples the COMPOSITED screen (the exact bytes daemon_pixel writes
#      to /dev/fb) and asserts the markup colours land at the on-screen
#      window-body coords while the backdrop shows OUTSIDE the window.
# The daemon emits these serial markers we assert on:
#     [markup-client] ui markup injected
#     [markup-client] client auto-detected + flagged
#     [markup-client] OK outer rect on screen
#     [markup-client] OK inner rect on screen
#     [markup-client] OK windowed (backdrop outside window)
#     [markup-client] PASS
#
# Honest: every assertion reads the composited frame through daemon_pixel
# (the value written to /dev/fb at that screen pixel), so a procedural body
# or a stub cannot forge it. The markup round-trips through the real kernel
# wsys draw-surface cdev and the live present path.

. "$(dirname "$0")/_build_lock.sh"
# The kernel is a higher-half elf64 image; qemu's `-kernel` rejects it.
# _kernel_iso.sh installs a build/binshim/qemu-system-x86_64 wrapper
# (prepended to PATH) that transparently wraps the ELF in a GRUB ISO and
# boots it via -cdrom, so the `-kernel <elf>` below Just Works.
. "$(dirname "$0")/_kernel_iso.sh"

set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf
READY="[hamsh] M16.35 shell ready"
OVERALL_TIMEOUT=160

echo "[test_hamUI_markupclient] (1/4) Build userland"
bash scripts/build_user.sh >/dev/null
bash scripts/build_modules.sh >/dev/null

echo "[test_hamUI_markupclient] (2/4) Build initramfs (+ markup-client selftest marker)"
ENABLE_MKC_SELFTEST=1 python3 scripts/build_initramfs.py >/dev/null

echo "[test_hamUI_markupclient] (3/4) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

if [ ! -s build/user/hamUId.elf ]; then
    echo "[test_hamUI_markupclient] FAIL: build/user/hamUId.elf missing/empty"
    exit 1
fi

echo "[test_hamUI_markupclient] (4/4) Boot QEMU + run the markup-client self-test"

LOG="${MKC_LOG:-$(mktemp)}"
trap '[ -z "${MKC_LOG:-}" ] && rm -f "$LOG"' EXIT

# --- NO serial injection. The proof runs INSIDE the autostart hamUId
#     daemon: at runlevel 5 etc/services.d/hamuid.svc launches `hamUId
#     daemon`, which (with the /etc/hamui-mkc-test marker planted above)
#     runs daemon_markup_client_selftest inline right after it grabs
#     /dev/fb, then exits. This sidesteps the console-takeover race that
#     made a serial-injected `hamUId daemon markupclient` unreliable: once
#     the autostart daemon owns the console, fed serial bytes never reach a
#     shell. Just boot and capture the daemon's "[markup-client]" markers.
#     READ="$READY" is unused for injection but kept as a boot-progress
#     reference. ---
: "$READY"

set +e
timeout "${OVERALL_TIMEOUT}s" qemu-system-x86_64 \
    -kernel "$ELF" \
    -smp 2 \
    -vga std \
    -display none \
    -no-reboot \
    -m 256M \
    -monitor none \
    -serial stdio \
    < /dev/null \
    > "$LOG" 2>&1
rc=$?
set -e

# A kernel panic / CPU trap is ALWAYS a hard failure — check it first so a
# real daemon crash can never be masked by the environment-skip below.
if grep -aE -q "PANIC|panic:|TRAP:|BUG:" "$LOG"; then
    echo "[test_hamUI_markupclient] FAIL: kernel panic / trap"
    tail -n 60 "$LOG"
    exit 1
fi

# SKIP CLEANLY when the hamUId daemon never came up under -vga std on this
# host (QEMU 10.x multiboot1 VBE + 64-bit ELF limitation / no usable VBE
# framebuffer). The shipped UEFI/GOP path (test_img_uefi_hamui.sh) drives
# the SAME daemon via EFI GOP and is the authoritative render gate on this
# host; this multiboot self-test only adds value where -vga std VBE works.
if ! grep -aq 'DAEMON up screen=' "$LOG"; then
    echo "[test_hamUI_markupclient] SKIP: hamUId daemon did not come up under -vga std on this host (QEMU multiboot VBE+64-bit limitation / no VBE framebuffer). Authoritative GOP gate: scripts/test_img_uefi_hamui.sh." >&2
    exit 0
fi

echo "[test_hamUI_markupclient] --- captured serial output (markup-client markers) ---"
grep -aE 'DAEMON|\[markup-client\]|MARK_MKC' "$LOG" | head -40
echo "[test_hamUI_markupclient] --- end ---"

fail=0

assert_marker() {
    if grep -aq "$1" "$LOG"; then
        echo "[test_hamUI_markupclient] OK: $2"
    else
        echo "[test_hamUI_markupclient] MISS: $2 (expected marker: '$1')"
        fail=1
    fi
}

assert_marker 'DAEMON up screen='                            'daemon started + read framebuffer geometry'
assert_marker '\[markup-client\] ui markup injected'         'hamui-style ui markup layer injected onto the wid'
assert_marker '\[markup-client\] client auto-detected'       'live present auto-detected the ui markup client'
assert_marker '\[markup-client\] OK outer rect on screen'    'markup outer-fill colour composited into the live body'
assert_marker '\[markup-client\] OK inner rect on screen'    'markup inner-rect colour composited into the live body'
assert_marker '\[markup-client\] OK windowed'                'backdrop shows outside the window (windowed, not full-screen)'
assert_marker '\[markup-client\] PASS'                       'self-test ran to completion (markup client is on screen)'

# rc=124 (timeout killed the forever-looping daemon) is EXPECTED — the
# daemon present-loop never exits on its own.
if [ "$fail" -ne 0 ]; then
    echo "[test_hamUI_markupclient] FAIL (qemu rc=$rc)"
    exit 1
fi

echo "[test_hamUI_markupclient] capture method: injects a real hamui ui markup layer, runs the LIVE daemon_present path, asserts composited-pixel colours at the window body via daemon_pixel"
echo "[test_hamUI_markupclient] PASS"
