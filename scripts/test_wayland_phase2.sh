#!/usr/bin/env bash
# scripts/test_wayland_phase2.sh -- Wayland-passthrough Phase 2 (wl_seat input).
#
# Builds on Phase 1 (shm buffer -> window). Proves the native in-kernel
# Wayland server (linux_abi/wayland.ad) routes Hamnix input to the focused
# Wayland surface as wl_seat events. An in-kernel client
# (wayland_phase2_selftest, linux_abi/u_syscalls.ad) drives the REAL socket
# syscalls (connect/sendmsg/recvmsg via linux_u_syscall_dispatch):
#   * bind wl_seat, wl_seat.get_pointer + get_keyboard;
#   * wl_keyboard.keymap: a us-layout XKB v1 keymap is passed to the client
#     over an SCM_RIGHTS memfd fd (asserted via a non-zero cmsg controllen);
#   * give its surface a window (shm pool + buffer + attach + commit);
#   * INJECT input through the SAME per-window /event + /keys rings the mouse
#     router / keyboard pump feed (wsys_wl_test_inject_pointer / _key);
#   * recvmsg drives the reactive server, which drains those rings and emits
#     wl_pointer enter/motion/button + wl_keyboard enter/key;
#   * assert the client received them (BTN_LEFT press, keycode 30 for 'a').
#
# Pass markers:  [wayland] wl_seat input delivered OK: WLPHASE2_OK
#                [wayland] PHASE2 PASS
# Fail marker:   [wayland] FAIL

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

export HAMNIX_BUILD_LOCK_TIMEOUT=900

ELF=build/hamnix-kernel.elf

echo "[test_wayland2] (1/3) Build userland (init)"
bash scripts/build_user.sh >/dev/null

echo "[test_wayland2] (2/3) Build kernel with /etc/wayland-test marker"
INIT_ELF=build/user/init.elf ENABLE_WAYLAND_TEST=1 \
    python3 scripts/build_initramfs.py >/dev/null
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1 || true' EXIT

echo "[test_wayland2] (3/3) Boot QEMU and run the Wayland Phase-2 input test"
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

echo "[test_wayland2] --- wayland self-test output ---"
grep -aE "\[wayland\]" "$LOG" || true
echo "[test_wayland2] --- end ---"

fail=0
if [ "$rc" -ne 0 ] && [ "$rc" -ne 124 ]; then
    echo "[test_wayland2] FAIL: qemu exited rc=$rc" >&2
    fail=1
fi
if grep -aqF "[wayland] FAIL" "$LOG"; then
    echo "[test_wayland2] FAIL: kernel self-test reported a failure" >&2
    grep -aF "[wayland] FAIL" "$LOG" | head -8 || true
    fail=1
fi
if grep -aqF "[wayland] wl_seat input delivered OK: WLPHASE2_OK" "$LOG"; then
    echo "[test_wayland2] wl_seat-input headline present"
else
    echo "[test_wayland2] FAIL: WLPHASE2_OK headline missing" >&2
    fail=1
fi
if grep -aqF "[wayland] PHASE2 PASS" "$LOG"; then
    echo "[test_wayland2] PHASE2 PASS banner present"
else
    echo "[test_wayland2] FAIL: PHASE2 PASS banner missing" >&2
    fail=1
fi
if [ "$fail" -ne 0 ]; then
    echo "[test_wayland2] FAIL"
    exit 1
fi
echo "[test_wayland2] PASS -- Hamnix input reaches a Wayland client's surface" \
     "as wl_pointer + wl_keyboard events via the native wl_seat"
