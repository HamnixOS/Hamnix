#!/usr/bin/env bash
# scripts/test_pidfd_getfd.sh — pidfd_getfd(2) (nr 438) cross-process
# fd-duplication verification.
#
# Proves the Linux-ABI pidfd_getfd syscall (linux_abi/u_pidfd_getfd.ad
# pidfd_getfd_handler, dispatched from linux_abi/u_syscalls.ad at nr 438) is a
# REAL cross-process file-descriptor duplication — it pulls an open file out of
# another process's fd table into the caller via the SAME copy_fd_entry backing
# share dup(2)/sys_srv_open(276) use — instead of returning ENOSYS. The
# in-kernel pidfd_getfd_selftest() (gated on the cpio marker
# /etc/pidfd-getfd-test) runs the round trip:
#   (1) open a real file fd in the boot task, derive a pidfd to SELF
#   (2) pidfd_getfd(pidfd, src_fd, 0) -> a NEW caller fd
#   (3) assert the new fd reaches the SAME backing object as src_fd (marker +
#       fd_buf identical) and that the duplicate survives closing the source fd
#   (4) flags!=0 -> EINVAL; a non-pidfd argument -> EBADF; a closed targetfd
#       -> EBADF
# The selftest does all the work and needs NO extra QEMU disk.
#
# Boot path: a raw 64-bit Hamnix ELF will NOT boot under `qemu -kernel` on this
# host; the _kernel_iso.sh PATH shim (sourced by _build_lock.sh) transparently
# wraps the ELFCLASS64 kernel in a BIOS GRUB ISO, so the `-kernel "$ELF"`
# invocation below boots through the ISO shim.
#
# Pass marker:  [test_pidfd_getfd] PASS   (kernel prints [pidfd-getfd] PASS)
# Fail marker:  [test_pidfd_getfd] FAIL

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

export HAMNIX_BUILD_LOCK_TIMEOUT="${HAMNIX_BUILD_LOCK_TIMEOUT:-900}"

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf

LOG=${HAMNIX_PIDFD_GETFD_LOG:-$(mktemp)}
trap 'INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1 || true' EXIT

echo "[test_pidfd_getfd] (1/3) Build userland + plant /etc/pidfd-getfd-test + /init"
bash scripts/build_user.sh >/dev/null
INIT_ELF="$HAMSH_ELF" ENABLE_PIDFD_GETFD_TEST=1 \
    python3 scripts/build_initramfs.py >/dev/null

echo "[test_pidfd_getfd] (2/3) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

echo "[test_pidfd_getfd] (3/3) Boot QEMU (no extra disk needed)"
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

echo "[test_pidfd_getfd] --- pidfd_getfd self-test output ---"
grep -a -E "\[pidfd-getfd\]|\[boot:37.pidfd_getfd\]" "$LOG" || true
echo "[test_pidfd_getfd] --- end ---"

fail=0

if grep -a -F -q "[pidfd-getfd] FAIL" "$LOG"; then
    echo "[test_pidfd_getfd] FAIL: kernel self-test reported an internal failure" >&2
    grep -a -F "[pidfd-getfd] FAIL" "$LOG" >&2 || true
    fail=1
fi

if ! grep -a -F -q "[pidfd-getfd] PASS" "$LOG"; then
    echo "[test_pidfd_getfd] MISS: self-test PASS banner (expected '[pidfd-getfd] PASS')" >&2
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_pidfd_getfd] --- full log ---"
    cat "$LOG"
    echo "[test_pidfd_getfd] FAIL (qemu rc=$rc)"
    exit 1
fi

echo "[test_pidfd_getfd] PASS — pidfd_getfd duplicates an fd across processes" \
     "as a real backing share (qemu rc=$rc)"
