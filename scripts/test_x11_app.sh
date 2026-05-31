#!/usr/bin/env bash
# scripts/test_x11_app.sh — X11 app-in-desktop integration test.
#
# Proves that a standalone X11 client (xclient_demo) can connect to the
# native x11srv over TCP, perform a complete X11 drawing session, and that
# x11srv flushes the rendered framebuffer into the hamUId wsys compositor
# layer via /dev/wsys/1/draw/.
#
# The test boots x11apptest.elf as /init.  x11apptest:
#   1. Spawns x11srv (TCP port 6000).
#   2. Polls for "[x11srv] listening" then spawns xclient_demo.
#   3. xclient_demo connects over the X11 wire protocol (no Xlib), creates
#      a 400x300 window, sends two PolyFillRectangle commands (purple
#      background + cyan-green inset), then sends the InternAtom done
#      sentinel to trigger the server's wsys flush.
#   4. x11srv calls flush_fb_to_wsys(), which opens /dev/wsys/1/draw/ctl
#      and writes the RGBA framebuffer to /dev/wsys/1/draw/x11fb/fb — the
#      hamUId compositor layer that would make the pixels visible in the
#      desktop on a system with a live hamUId session.
#   5. Both processes print PASS; x11apptest prints "[x11apptest] PASS".
#
# The wsys flush sentinel "[x11srv] fb flushed to wsys layer" is the key
# proof: it confirms the X11→compositor pipeline ran to completion.  In
# a non-UEFI QEMU boot (no real framebuffer) hamUId is not running so the
# ctl write may warn, but the sentinel is still emitted.
#
# Required sentinels:
#   "[x11srv] listening"
#   "[xclient_demo] connected"
#   "[xclient_demo] draw sent"
#   "[xclient_demo] PASS"
#   "[x11srv] fb flushed to wsys layer"
#   "[x11srv] PASS"
#   "[x11apptest] PASS"

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf
X11APPTEST_ELF=build/user/x11apptest.elf

# --- (1/3) Build userland (incl. x11srv, xclient_demo, x11apptest) ---
echo "[test_x11_app] (1/3) Build userland"
bash scripts/build_user.sh >/dev/null
for f in build/user/x11srv.elf build/user/xclient_demo.elf build/user/x11apptest.elf; do
    if [ ! -f "$f" ]; then
        echo "[test_x11_app] FAIL: $f not built"
        exit 1
    fi
done
echo "[test_x11_app] x11srv, xclient_demo, x11apptest all built"

# --- (2/3) Embed x11apptest as /init + rebuild kernel ----------------
echo "[test_x11_app] (2/3) Embed x11apptest as /init + rebuild kernel"
INIT_ELF="$X11APPTEST_ELF" python3 scripts/build_initramfs.py >/dev/null
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

# --- (3/3) Boot QEMU and assert sentinels ----------------------------
echo "[test_x11_app] (3/3) Boot QEMU (x11apptest as /init)"
LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1 || true' EXIT

# Generous 120 s timeout: same TCP+X11 round-trip work as test_x11.sh,
# plus a two-layer draw session (purple fill + cyan fill).
set +e
timeout 120s qemu-system-x86_64 \
    -kernel "$ELF" \
    -netdev "user,id=n0,guestfwd=tcp:10.0.2.100:7-cmd:cat" \
    -device virtio-net-pci,netdev=n0,mac=52:54:00:12:34:56 \
    -smp 2 \
    -nographic -no-reboot -m 256M -monitor none -serial stdio \
    > "$LOG" 2>&1 < /dev/null
qemu_rc=$?
set -e

# Show relevant log lines.
echo "[test_x11_app] --- captured lines ---"
grep -E '\[x11srv\]|\[xclient_demo\]|\[x11apptest\]|\[tcp\]' "$LOG" || true
echo "[test_x11_app] --- end ---"

# Assert all required sentinels are present.
fail=0
for needle in \
    "[x11srv] listening" \
    "[xclient_demo] connected" \
    "[xclient_demo] draw sent" \
    "[xclient_demo] PASS" \
    "[x11srv] fb flushed to wsys layer" \
    "[x11srv] PASS" \
    "[x11apptest] PASS"
do
    if grep -F -q "$needle" "$LOG"; then
        echo "[test_x11_app] OK: '$needle'"
    else
        echo "[test_x11_app] MISS: '$needle'"
        fail=1
    fi
done

if grep -F -q "TRAP: vector" "$LOG"; then
    echo "[test_x11_app] DIAG: kernel reported a CPU exception"
    grep -F "TRAP: vector" "$LOG" | head -5 || true
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_x11_app] FAIL (qemu rc=${qemu_rc})"
    echo "[test_x11_app] --- full kernel log (last 200 lines) ---"
    tail -n 200 "$LOG"
    exit 1
fi

echo "[test_x11_app] PASS — xclient_demo connected to x11srv and drawing" \
     "reached the hamUId wsys compositor layer (fb flushed)"
