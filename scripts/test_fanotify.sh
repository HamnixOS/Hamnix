#!/usr/bin/env bash
# scripts/test_fanotify.sh -- fanotify(7) for the Linux ABI.
#
# fanotify is inotify's sibling: the SAME inode-event source (fs/vfs.ad's
# create/delete/modify/close hook, fed through a combined dispatcher
# registered at bring-up), but a fixed-size struct fanotify_event_metadata
# read format and a per-group mark list. Both handlers live in
# linux_abi/u_syscalls.ad (_u_fanotify_init / _u_fanotify_mark + the
# FD_FANOTIFY_MARK read shim) and are wired into the central Linux-ABI
# dispatcher at their standard x86_64 syscall numbers (300 / 301).
#
# This boots the kernel once with /etc/fanotify-test planted
# (ENABLE_FANOTIFY_TEST=1); init/main.ad's gate (boot:37.fanotify) calls
# fanotify_selftest() (linux_abi/u_syscalls.ad), which drives, in boot
# context, the SAME code the syscall entry points call:
#
#   * fanotify_init(FAN_CLASS_NOTIF|FAN_NONBLOCK) -> a group fd; the
#     permission class FAN_CLASS_CONTENT is rejected with EINVAL.
#   * fanotify_mark(ADD, FAN_MODIFY, "/tmp"); an unsourceable mask bit
#     (FAN_OPEN) is rejected with EINVAL.
#   * write a /tmp file -> the tmpfs write arm posts IN_MODIFY through the
#     combined notify hook into the fanotify pool.
#   * read(group_fd) -> assert one struct fanotify_event_metadata with
#     vers == 3 (FANOTIFY_METADATA_VERSION), event_len == 24, and a mask
#     carrying FAN_MODIFY; fd == FAN_NOFD (-1, scoped).
#   * FAN_MARK_FLUSH, then a non-blocking read drains to EAGAIN.
#
# Pass marker:  [fanotify] PASS
# Fail marker:  [fanotify] FAIL

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

export HAMNIX_BUILD_LOCK_TIMEOUT=900

ELF=build/hamnix-kernel.elf

echo "[test_fanotify] (1/3) Build userland (init)"
bash scripts/build_user.sh >/dev/null

echo "[test_fanotify] (2/3) Build kernel with /etc/fanotify-test marker"
INIT_ELF=build/user/init.elf ENABLE_FANOTIFY_TEST=1 \
    python3 scripts/build_initramfs.py >/dev/null
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1 || true' EXIT

echo "[test_fanotify] (3/3) Boot QEMU and run the fanotify self-test"
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

echo "[test_fanotify] --- fanotify self-test output ---"
grep -aE "\[fanotify\]" "$LOG" || true
echo "[test_fanotify] --- end ---"

fail=0

if [ "$rc" -ne 0 ] && [ "$rc" -ne 124 ]; then
    echo "[test_fanotify] FAIL: qemu exited rc=$rc" >&2
    fail=1
fi

# An explicit internal failure is fatal.
if grep -aqF "[fanotify] FAIL" "$LOG"; then
    echo "[test_fanotify] FAIL: kernel self-test reported a failure" >&2
    grep -aF "[fanotify] FAIL" "$LOG" | head -5 || true
    fail=1
fi

# The kernel prints exactly "[fanotify] PASS" on its own line (after an
# optional "[NNNNNN] " printk timestamp prefix) only when EVERY assertion
# held. Anchor to end-of-line so the per-leg "[fanotify] ... OK" lines do
# not satisfy it.
if grep -aqE '(^|\] )\[fanotify\] PASS$' "$LOG"; then
    echo "[test_fanotify] PASS: overall self-test PASS banner"
else
    echo "[test_fanotify] FAIL: overall self-test PASS banner missing" >&2
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_fanotify] FAIL"
    exit 1
fi

echo "[test_fanotify] PASS -- fanotify_init/mark drive a real group, a /tmp" \
     "write posts FAN_MODIFY through the shared fsnotify source, and read()" \
     "returns a struct fanotify_event_metadata (vers=3, mask=FAN_MODIFY);" \
     "permission classes + unsourceable masks are EINVAL, flush+drain EAGAIN"
