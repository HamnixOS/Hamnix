#!/usr/bin/env bash
# scripts/test_wayland_phase1.sh -- Wayland-passthrough Phase 1.
#
# Proves the native in-kernel Wayland server (linux_abi/wayland.ad) takes a
# Wayland CLIENT from connect() through a committed wl_shm buffer onto a
# Hamnix scene window. An in-kernel client (wayland_phase1_selftest,
# linux_abi/u_syscalls.ad) drives the REAL socket syscalls
# (connect/sendmsg/recvmsg via linux_u_syscall_dispatch, exactly as
# libwayland would):
#   * connect to a "wayland-0" AF_UNIX name -> lazily binds the display
#     listener + accepts/registers the connection (u_syscalls connect hook);
#   * get_registry -> wl_compositor / wl_shm / xdg_wm_base advertised;
#   * bind wl_compositor + wl_shm;
#   * memfd_create + mmap MAP_SHARED, paint a solid colour, pass the pool fd
#     via SCM_RIGHTS in create_pool (Phase-0 shm path);
#   * create_buffer + create_surface + attach + commit;
#   * assert the ARGB8888 pixels reached the window's v2 backbuffer AND the
#     compositor layer cache (the buffer-verb present-path wiring in
#     sys/src/9/port/devwsys.ad).
#
# Pass markers:  [wayland] shm buffer on screen OK: WLPHASE1_OK
#                [wayland] PASS
# Fail marker:   [wayland] FAIL

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

export HAMNIX_BUILD_LOCK_TIMEOUT=900

ELF=build/hamnix-kernel.elf

echo "[test_wayland] (1/3) Build userland (init)"
bash scripts/build_user.sh >/dev/null

echo "[test_wayland] (2/3) Build kernel with /etc/wayland-test marker"
INIT_ELF=build/user/init.elf ENABLE_WAYLAND_TEST=1 \
    python3 scripts/build_initramfs.py >/dev/null
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1 || true' EXIT

echo "[test_wayland] (3/3) Boot QEMU and run the Wayland Phase-1 client test"
set +e
timeout 180s qemu-system-x86_64 \
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

echo "[test_wayland] --- wayland self-test output ---"
grep -aE "\[wayland\]" "$LOG" || true
echo "[test_wayland] --- end ---"

fail=0
if [ "$rc" -ne 0 ] && [ "$rc" -ne 124 ]; then
    echo "[test_wayland] FAIL: qemu exited rc=$rc" >&2
    fail=1
fi
if grep -aqF "[wayland] FAIL" "$LOG"; then
    echo "[test_wayland] FAIL: kernel self-test reported a failure" >&2
    grep -aF "[wayland] FAIL" "$LOG" | head -5 || true
    fail=1
fi
if grep -aqF "[wayland] shm buffer on screen OK: WLPHASE1_OK" "$LOG"; then
    echo "[test_wayland] shm-buffer-to-window headline present"
else
    echo "[test_wayland] FAIL: WLPHASE1_OK headline missing" >&2
    fail=1
fi
if grep -aqE '(^|\] )\[wayland\] PASS$' "$LOG"; then
    echo "[test_wayland] PASS banner present"
else
    echo "[test_wayland] FAIL: overall PASS banner missing" >&2
    fail=1
fi
if [ "$fail" -ne 0 ]; then
    echo "[test_wayland] FAIL"
    exit 1
fi
echo "[test_wayland] PASS -- a Linux-ns Wayland client's committed wl_shm" \
     "buffer lands on a Hamnix window via the native Wayland server"
