#!/usr/bin/env bash
# scripts/test_wlspike_scm.sh -- Wayland-passthrough Phase-0 de-risk spike.
#
# THE make-or-break experiment for docs/wayland_passthrough_design.md: prove
# that a shared-memory (memfd) buffer fd can cross the Linux-ns boundary via
# an AF_UNIX SCM_RIGHTS ancillary message (sendmsg/recvmsg) and that the SAME
# physical page is visible on BOTH ends. If this holds, the Wayland wl_shm
# pixel pipeline is de-risked (§7.1 / §8 retired).
#
# Implementation exercised (all NEW on this branch):
#   * linux_abi/u_syscalls.ad : sendmsg(46)/recvmsg(47) dispatched (were
#     -ENOSYS) with a real struct msghdr / iovec / cmsghdr(SCM_RIGHTS) parse;
#     resolve a passed memfd fd to its tmpfs backing slot on send, install a
#     FRESH fd bound to the SAME slot on recv.
#   * linux_abi/u_unixsock.ad : per-endpoint SCM ancillary-fd conduit
#     alongside the byte ring.
#   * fs/tmpfs.ad : anon-slot dup refcount so a memfd passed across the
#     socket is not freed while a peer still maps it.
#   * fs/vfs.ad : vfs_install_tmpfs_slot_fd (receiver-side fd bind).
#
# The self-test wlspike_scm_selftest() (gated on /etc/wlspike-test) drives
# the REAL sendmsg/recvmsg dispatch through genuine user memory, exactly as
# libwayland would, then asserts:
#   - the 8-byte data iov transferred,
#   - recvmsg returned a NEW fd in the SCM_RIGHTS cmsg,
#   - tmpfs_page_phys(send) == tmpfs_page_phys(recv)  (SAME physical frame),
#   - a fresh MAP_SHARED mmap of the received fd reads back the marker
#     "WLSPIKE_OK" written through the sender's mapping.
#
# Pass marker:  [wlspike] SCM_RIGHTS memfd round-trip OK: WLSPIKE_OK
#               [wlspike] PASS
# Fail marker:  [wlspike] FAIL

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

export HAMNIX_BUILD_LOCK_TIMEOUT=900

ELF=build/hamnix-kernel.elf

echo "[test_wlspike] (1/3) Build userland (init)"
bash scripts/build_user.sh >/dev/null

echo "[test_wlspike] (2/3) Build kernel with /etc/wlspike-test marker"
INIT_ELF=build/user/init.elf ENABLE_WLSPIKE_TEST=1 \
    python3 scripts/build_initramfs.py >/dev/null
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1 || true' EXIT

echo "[test_wlspike] (3/3) Boot QEMU and run the SCM_RIGHTS round-trip test"
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

echo "[test_wlspike] --- wlspike self-test output ---"
grep -aE "\[wlspike\]" "$LOG" || true
echo "[test_wlspike] --- end ---"

fail=0

if [ "$rc" -ne 0 ] && [ "$rc" -ne 124 ]; then
    echo "[test_wlspike] FAIL: qemu exited rc=$rc" >&2
    fail=1
fi

if grep -aqF "[wlspike] FAIL" "$LOG"; then
    echo "[test_wlspike] FAIL: kernel self-test reported a failure" >&2
    grep -aF "[wlspike] FAIL" "$LOG" | head -5 || true
    fail=1
fi

# The de-risk headline: a passed memfd fd resolves to the SAME physical
# frame on the receiver, and the marker round-trips through it.
if grep -aqF "[wlspike] SCM_RIGHTS memfd round-trip OK: WLSPIKE_OK" "$LOG"; then
    echo "[test_wlspike] round-trip headline present"
else
    echo "[test_wlspike] FAIL: SCM_RIGHTS round-trip headline missing" >&2
    fail=1
fi

if grep -aqE '(^|\] )\[wlspike\] PASS$' "$LOG"; then
    echo "[test_wlspike] PASS banner present"
else
    echo "[test_wlspike] FAIL: overall PASS banner missing" >&2
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_wlspike] FAIL"
    exit 1
fi

echo "[test_wlspike] PASS -- a memfd fd passed over AF_UNIX SCM_RIGHTS lands" \
     "on the SAME physical page in the receiver; Wayland shm pipeline de-risked"
