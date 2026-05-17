#!/usr/bin/env bash
# scripts/test_u32_busybox_ls.sh -- U32: drive busybox-static through
# hamsh to enumerate a real directory via getdents64.
#
# Builds on U29 (busybox banner reached user mode) and U31 (signal
# delivery). With U32 in place, vfs_open() snapshots cpio directories
# into a kmalloc'd NAME\n buffer parked on the fd, and getdents64()
# repackages successive entries as struct linux_dirent64. busybox's
# ls applet now sees real directory contents when pointed at /etc
# (a flat cpio dir with ~20 files: motd, hostname, hosts, ...).
#
# Strategy: boot hamsh, run `busybox ls /etc` (we copy u_busybox to
# /bin/busybox so the basename-dispatched applet works), assert that
# at least two known filenames from etc/ appear in the output.

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

UBIN=tests/u-binary/u_busybox

if [ ! -f "$UBIN" ]; then
    echo "[test_u32_busybox_ls] SKIP: $UBIN not staged"
    exit 0
fi

ELF=build/hamnix-vmlinux.elf
HAMSH_ELF=build/user/hamsh.elf

echo "[test_u32_busybox_ls] (1/4) Build userland + modules"
bash scripts/build_user.sh
bash scripts/build_modules.sh

echo "[test_u32_busybox_ls] (2/4) Swap /init=hamsh + embed busybox"
cp tests/u-binary/u_busybox tests/u-binary/busybox
HAMNIX_EMBED_UBIN=1 INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py

echo "[test_u32_busybox_ls] (3/4) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF"

echo "[test_u32_busybox_ls] (4/4) Boot QEMU + run busybox ls /etc"
LOG=$(mktemp)
trap 'rm -f "$LOG" tests/u-binary/busybox; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null' EXIT

set +e
(
    sleep 3
    printf 'busybox ls /etc\n'
    sleep 6
    printf 'exit\n'
    sleep 1
) | timeout 45s qemu-system-x86_64 \
    -kernel "$ELF" \
    -smp 2 \
    -nographic \
    -no-reboot \
    -m 256M \
    -monitor none \
    -serial stdio \
    > "$LOG" 2>&1
rc=$?
set -e

echo "[test_u32_busybox_ls] --- captured output (last 250 lines) ---"
tail -n 250 "$LOG"
echo "[test_u32_busybox_ls] --- end output ---"

fail=0

# Expected /etc entries from etc/ directory: motd, hostname, hosts,
# passwd, group, profile, resolv.conf, fstab, inittab, ...
# Bar: at least 2 distinct names must appear.
hits=0
for name in motd hostname hosts passwd group profile fstab inittab \
            issue services protocols shells timezone; do
    if grep -F -q "$name" "$LOG"; then
        hits=$((hits + 1))
    fi
done

if [ "$hits" -lt 2 ]; then
    echo "[test_u32_busybox_ls] FAIL: only $hits known /etc names found (need >=2)"
    fail=1
else
    echo "[test_u32_busybox_ls] OK: $hits known /etc names appeared in output"
fi

if grep -F -q "TRAP: vector" "$LOG"; then
    echo "[test_u32_busybox_ls] DIAG: kernel reported a CPU exception"
    grep -F "TRAP: vector" "$LOG" | head -5 || true
    fail=1
fi
if grep -F -q "unknown syscall" "$LOG"; then
    echo "[test_u32_busybox_ls] DIAG: unknown syscall(s)"
    grep -F "unknown syscall" "$LOG" | sort -u | head -10 || true
fi
if grep -F -q "page fault" "$LOG"; then
    echo "[test_u32_busybox_ls] DIAG: page fault"
    grep -F "page fault" "$LOG" | head -5 || true
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_u32_busybox_ls] FAIL (qemu rc=$rc)"
    exit 1
fi

echo "[test_u32_busybox_ls] PASS -- busybox ls /etc enumerated via getdents64"
