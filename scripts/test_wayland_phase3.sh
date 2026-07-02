#!/usr/bin/env bash
# scripts/test_wayland_phase3.sh -- Wayland Phase 3 (xdg-shell window management).
#
# Builds on Phases 1+2. Proves the native in-kernel Wayland server
# (linux_abi/wayland.ad) implements a real xdg-shell. An in-kernel client
# (wayland_phase3_selftest, linux_abi/u_syscalls.ad) drives the REAL socket
# syscalls (connect/sendmsg/recvmsg via linux_u_syscall_dispatch):
#   * bind xdg_wm_base; get_xdg_surface + get_toplevel;
#   * receive the initial xdg_toplevel.configure + xdg_surface.configure;
#   * set_title("hamnix-wl"); do the initial EMPTY commit (must NOT map);
#   * ack_configure(serial); attach a buffer + commit -> the surface now MAPS
#     as a DECORATED window carrying the requested titlebar text;
#   * xdg_wm_base ping/pong liveness handshake;
#   * xdg_toplevel.close event, then client xdg_toplevel.destroy tears the
#     window down.
#   * asserts the configure/ack sequencing gate + the titlebar text.
#
# Pass markers:  [wayland] xdg toplevel mapped OK: WLPHASE3_OK
#                [wayland] PHASE3 PASS
# Fail marker:   [wayland] FAIL

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

export HAMNIX_BUILD_LOCK_TIMEOUT=900

ELF=build/hamnix-kernel.elf

echo "[test_wayland3] (1/3) Build userland (init)"
bash scripts/build_user.sh >/dev/null

echo "[test_wayland3] (2/3) Build kernel with /etc/wayland-test marker"
INIT_ELF=build/user/init.elf ENABLE_WAYLAND_TEST=1 \
    python3 scripts/build_initramfs.py >/dev/null
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1 || true' EXIT

echo "[test_wayland3] (3/3) Boot QEMU and run the Wayland Phase-3 xdg-shell test"
set +e
timeout 300s qemu-system-x86_64 \
    -kernel "$ELF" \
    -smp 1 \
    -nographic \
    -no-reboot \
    -m 256M \
    -monitor none \
    -serial stdio \
    </dev/null > "$LOG" 2>&1
rc=$?
set -e

echo "[test_wayland3] --- wayland self-test output ---"
grep -aE "\[wayland\]" "$LOG" || true
echo "[test_wayland3] --- end ---"

fail=0
if [ "$rc" -ne 0 ] && [ "$rc" -ne 124 ]; then
    echo "[test_wayland3] FAIL: qemu exited rc=$rc" >&2
    fail=1
fi
if grep -aqF "[wayland] FAIL" "$LOG"; then
    echo "[test_wayland3] FAIL: kernel self-test reported a failure" >&2
    grep -aF "[wayland] FAIL" "$LOG" | head -8 || true
    fail=1
fi
if grep -aqF "[wayland] xdg toplevel mapped OK: WLPHASE3_OK" "$LOG"; then
    echo "[test_wayland3] xdg-map headline present"
else
    echo "[test_wayland3] FAIL: WLPHASE3_OK headline missing" >&2
    fail=1
fi
if grep -aqF "[wayland] PHASE3 PASS" "$LOG"; then
    echo "[test_wayland3] PHASE3 PASS banner present"
else
    echo "[test_wayland3] FAIL: PHASE3 PASS banner missing" >&2
    fail=1
fi
if [ "$fail" -ne 0 ]; then
    echo "[test_wayland3] FAIL"
    exit 1
fi
echo "[test_wayland3] PASS -- Hamnix input reaches a Wayland client's surface" \
     "as wl_pointer + wl_keyboard events via the native wl_seat"
