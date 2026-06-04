#!/usr/bin/env bash
# scripts/test_quota.sh — disk-quota (quotactl) round-trip verification.
#
# Proves the Linux-ABI disk-quota syscall (linux_abi/u_quota.ad
# uquota_quotactl, dispatched from linux_abi/u_syscalls.ad at nr 179) is backed
# by a REAL per-(filesystem, type, id) quota store with actual block/inode
# limit + usage accounting, instead of returning ENOSYS or ignoring its
# arguments. The in-kernel quota_selftest() (gated on the cpio marker
# /etc/quota-test) runs the real checks:
#   (1) Q_QUOTAON the root fs -> 0
#   (2) Q_SETQUOTA a dqblk (block+inode hard/soft limits + live usage for a
#       uid); Q_GETQUOTA reads it back and asserts every field is byte-exact
#   (3) Q_SETINFO grace times; Q_GETINFO asserts they round-trip
#   (4) Q_QUOTAOFF then Q_GETQUOTA -> ESRCH (off-state observable)
#   (5) a bad cmd -> EINVAL; a bad type -> EINVAL; an unknown special -> ENODEV
# The selftest does all the work and needs NO extra disk.
#
# Boot path: a raw 64-bit Hamnix ELF will NOT boot under `qemu -kernel` on this
# host; the _kernel_iso.sh PATH shim (sourced by _build_lock.sh) transparently
# wraps the ELFCLASS64 kernel in a BIOS GRUB ISO, so the `-kernel "$ELF"`
# invocation below boots through the ISO shim.
#
# Pass marker:  [test_quota] PASS   (kernel prints [quota] PASS)
# Fail marker:  [test_quota] FAIL

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

export HAMNIX_BUILD_LOCK_TIMEOUT="${HAMNIX_BUILD_LOCK_TIMEOUT:-900}"

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf

LOG=${HAMNIX_QUOTA_LOG:-$(mktemp)}
trap 'INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1 || true' EXIT

echo "[test_quota] (1/3) Build userland + plant /etc/quota-test + /init"
bash scripts/build_user.sh >/dev/null
INIT_ELF="$HAMSH_ELF" ENABLE_QUOTA_TEST=1 \
    python3 scripts/build_initramfs.py >/dev/null

echo "[test_quota] (2/3) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

echo "[test_quota] (3/3) Boot QEMU (no extra disk needed)"
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

echo "[test_quota] --- quota self-test output ---"
grep -a -E "\[QUOTA\]|\[quota\]" "$LOG" || true
echo "[test_quota] --- end ---"

fail=0

if grep -a -F -q "[QUOTA] FAIL" "$LOG"; then
    echo "[test_quota] FAIL: kernel self-test reported an internal failure" >&2
    grep -a -F "[QUOTA] FAIL" "$LOG" >&2 || true
    fail=1
fi

if grep -a -F -q "[quota] self-test reported FAIL" "$LOG"; then
    echo "[test_quota] FAIL: quota_selftest returned failure" >&2
    fail=1
fi

if ! grep -a -F -q "[quota] PASS" "$LOG"; then
    echo "[test_quota] MISS: self-test PASS banner (expected '[quota] PASS')" >&2
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_quota] --- full log ---"
    cat "$LOG"
    echo "[test_quota] FAIL (qemu rc=$rc)"
    exit 1
fi

echo "[test_quota] PASS — Q_SETQUOTA/Q_GETQUOTA + Q_SETINFO/Q_GETINFO round-trip" \
     "through the per-(fs,type,id) quota store; Q_QUOTAON/OFF enforced (qemu rc=$rc)"
