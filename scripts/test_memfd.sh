#!/usr/bin/env bash
# scripts/test_memfd.sh -- Linux memfd_create(2) + file sealing.
#
# Real Linux software (Wayland/graphics clients, dconf, dbus, language
# runtimes) reaches for memfd_create(2) plus fcntl(F_ADD_SEALS) to make
# an anonymous, growable, optionally sealable RAM-backed file. The
# implementation lives in linux_abi/u_memfd.ad (handlers) backed by the
# existing tmpfs store (fs/tmpfs.ad) through the FD_TMPFS_MARK fd
# machinery (fs/vfs.ad), and is wired into the central Linux-ABI
# dispatcher (linux_abi/u_syscalls.ad) at memfd_create=319 plus the
# fcntl F_ADD_SEALS=1033 / F_GET_SEALS=1034 commands.
#
# This test boots the kernel once with /etc/memfd-test planted
# (ENABLE_MEMFD_TEST=1); init/main.ad's memfd gate (boot:37.memfd) calls
# memfd_selftest() (linux_abi/u_memfd.ad), which exercises every
# primitive directly in boot context (driving the same code the syscall
# entry points call):
#
#   * memfd_create (MFD_ALLOW_SEALING) -> writable/readable anon file;
#     write 12 bytes, read them back byte-exact.
#   * F_SEAL_WRITE -> a subsequent write makes no progress (EPERM); the
#     seal is visible via F_GET_SEALS.
#   * F_SEAL_GROW -> ftruncate-larger EPERMs AND an extending write past
#     EOF is refused (the file does not grow).
#   * adding any seal to a memfd created WITHOUT MFD_ALLOW_SEALING EPERMs.
#   * F_SEAL_SEAL -> any further seal EPERMs.
#
# Pass marker:  [memfd] PASS
# Fail marker:  [memfd] FAIL

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

export HAMNIX_BUILD_LOCK_TIMEOUT=900

ELF=build/hamnix-kernel.elf

echo "[test_memfd] (1/3) Build userland (init)"
bash scripts/build_user.sh >/dev/null

echo "[test_memfd] (2/3) Build kernel with /etc/memfd-test marker"
INIT_ELF=build/user/init.elf ENABLE_MEMFD_TEST=1 \
    python3 scripts/build_initramfs.py >/dev/null
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1 || true' EXIT

echo "[test_memfd] (3/3) Boot QEMU and run the memfd self-test"
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

echo "[test_memfd] --- memfd self-test output ---"
grep -aE "\[memfd\]" "$LOG" || true
echo "[test_memfd] --- end ---"

fail=0

if [ "$rc" -ne 0 ] && [ "$rc" -ne 124 ]; then
    echo "[test_memfd] FAIL: qemu exited rc=$rc" >&2
    fail=1
fi

# An explicit internal failure is fatal.
if grep -aqF "[memfd] FAIL" "$LOG"; then
    echo "[test_memfd] FAIL: kernel self-test reported a failure" >&2
    grep -aF "[memfd] FAIL" "$LOG" | head -5 || true
    fail=1
fi

# The kernel prints exactly "[memfd] PASS" on its own line (after an
# optional "[NNNNNN] " printk timestamp prefix) only when EVERY assertion
# held. Anchor to end-of-line so the per-assertion "[memfd] PASS: ..."
# lines (trailing ": ...") don't satisfy it.
if grep -aqE '(^|\] )\[memfd\] PASS$' "$LOG"; then
    echo "[test_memfd] PASS: overall self-test PASS banner"
else
    echo "[test_memfd] FAIL: overall self-test PASS banner missing" >&2
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_memfd] FAIL"
    exit 1
fi

echo "[test_memfd] PASS -- memfd_create round-trips bytes, and" \
     "F_SEAL_WRITE / F_SEAL_GROW / F_SEAL_SEAL plus the non-ALLOW_SEALING" \
     "EPERM rule are all enforced"
