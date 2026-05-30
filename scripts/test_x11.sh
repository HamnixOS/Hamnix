#!/usr/bin/env bash
# scripts/test_x11.sh — X11 server/client round-trip smoke test.
#
# Tests the first working slice of the Hamnix native X11 server (user/x11/).
#
# The test boots x11test.elf as /init. x11test spawns two processes
# inside the guest:
#   1. x11srv — a minimal X11 server on TCP port 6000 that renders
#      client drawing commands into a wsys draw fb layer.
#   2. xfill  — a demo X11 client that connects to 127.0.0.1:6000,
#      creates a window, creates two GCs, and fills two coloured
#      rectangles via PolyFillRectangle.
#
# Both are pure native Adder binaries speaking the raw X11 wire
# protocol over the Plan-9 /net/tcp file tree — no Xlib, no sockets.
#
# All I/O stays inside the QEMU guest (guest-loopback TCP); the host
# sees only the kernel serial log. No hostfwd needed.
#
# Required sentinels (all must appear in the kernel log):
#   "[x11srv] listening"
#   "[x11srv] CreateWindow"
#   "[x11srv] MapWindow"
#   "[x11srv] PolyFillRectangle"
#   "[x11srv] PASS"
#   "[xfill] connected"
#   "[xfill] fill1 sent"
#   "[xfill] PASS"
#   "[x11test] PASS"
#
# The PolyFillRectangle sentinel confirms a CreateWindow + CreateGC +
# draw round-trip completed end to end at the protocol layer.

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf
X11TEST_ELF=build/user/x11test.elf

# --- (1/3) Build userland (incl. x11srv, xfill, x11test) ------------
echo "[test_x11] (1/3) Build userland"
bash scripts/build_user.sh >/dev/null
for f in build/user/x11srv.elf build/user/xfill.elf build/user/x11test.elf; do
    if [ ! -f "$f" ]; then
        echo "[test_x11] FAIL: $f not built"
        exit 1
    fi
done
echo "[test_x11] x11srv, xfill, x11test all built"

# --- (2/3) Embed x11test as /init + rebuild kernel ------------------
echo "[test_x11] (2/3) Embed x11test as /init + rebuild kernel"
INIT_ELF="$X11TEST_ELF" python3 scripts/build_initramfs.py >/dev/null
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

# --- (3/3) Boot QEMU and assert sentinels ---------------------------
echo "[test_x11] (3/3) Boot QEMU (x11test as /init)"
LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1 || true' EXIT

# x11test does all the work inside the guest:
#   x11srv announces :6000 -> xfill connects -> protocol exchange -> both PASS.
# Generous 120 s timeout (TCG is slow; server + client spawn + TCP handshake
# + X11 round-trip can take 30-60 s on a loaded host).
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
echo "[test_x11] --- captured lines ---"
grep -E '\[x11srv\]|\[xfill\]|\[x11test\]|\[net\]|\[tcp\]' "$LOG" || true
echo "[test_x11] --- end ---"

# Assert all required sentinels are present.
fail=0
for needle in \
    "[x11srv] listening" \
    "[x11srv] CreateWindow" \
    "[x11srv] MapWindow" \
    "[x11srv] PolyFillRectangle" \
    "[x11srv] PASS" \
    "[xfill] connected" \
    "[xfill] fill1 sent" \
    "[xfill] PASS" \
    "[x11test] PASS"
do
    if grep -F -q "$needle" "$LOG"; then
        echo "[test_x11] OK: '$needle'"
    else
        echo "[test_x11] MISS: '$needle'"
        fail=1
    fi
done

if grep -F -q "TRAP: vector" "$LOG"; then
    echo "[test_x11] DIAG: kernel reported a CPU exception"
    grep -F "TRAP: vector" "$LOG" | head -5 || true
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_x11] FAIL (qemu rc=${qemu_rc})"
    echo "[test_x11] --- full kernel log (last 200 lines) ---"
    tail -n 200 "$LOG"
    exit 1
fi

echo "[test_x11] PASS — X11 CreateWindow+MapWindow+CreateGC+PolyFillRectangle" \
     "round-trip completed end-to-end over the native /net/tcp stack"
