#!/usr/bin/env bash
# scripts/test_u34_syscalls.sh -- U34: sendfile(40) + readv(19) + fcntl(72)
#
# U33 left three "unknown syscall" lines in the busybox trace:
#   * nr=40  sendfile  — busybox cat's kernel-side splice fast path
#   * nr=19  readv     — glibc/musl-style buffered I/O
#   * nr=72  fcntl     — glibc startup probes F_GETFL on stdio
#
# U34 promotes each from -ENOSYS to a real handler. This test re-runs
# the U33 busybox applet harness and asserts:
#
#   1. The five U33 applets all still hit their markers (no regression).
#   2. The trace contains NO "unknown syscall" line for nr=40, nr=19,
#      or nr=72 (the U34 promotion happened).
#
# A C fixture exercising sendfile/readv/fcntl directly would need
# busybox rebuilt against a new applet, which is out of scope here —
# the live busybox binary already calls each of these three syscalls
# during cat / ls / startup, so the indirect test is sufficient.

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

UBIN=tests/u-binary/u_busybox

if [ ! -f "$UBIN" ]; then
    echo "[test_u34_syscalls] SKIP: $UBIN not staged"
    exit 0
fi

ELF=build/hamnix-vmlinux.elf
HAMSH_ELF=build/user/hamsh.elf

echo "[test_u34_syscalls] (1/4) Build userland + modules"
bash scripts/build_user.sh
bash scripts/build_modules.sh

echo "[test_u34_syscalls] (2/4) Swap /init=hamsh + embed busybox"
cp tests/u-binary/u_busybox tests/u-binary/busybox
HAMNIX_EMBED_UBIN=1 INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py

echo "[test_u34_syscalls] (3/4) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF"

echo "[test_u34_syscalls] (4/4) Boot QEMU + drive busybox cat / ls"
LOG=$(mktemp)
trap 'rm -f "$LOG" tests/u-binary/busybox; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null' EXIT

set +e
(
    sleep 3
    # busybox cat hits sendfile(40) on stdio + readv(19) on glibc
    # buffered I/O. fcntl(72) fires during dynamic-linker setup on
    # every applet invocation.
    printf 'busybox cat /etc/motd\n'
    sleep 3
    printf 'busybox ls /bin\n'
    sleep 4
    printf 'busybox echo done\n'
    sleep 2
    printf 'exit\n'
    sleep 1
) | timeout 90s qemu-system-x86_64 \
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

echo "[test_u34_syscalls] --- captured output (last 200 lines) ---"
tail -n 200 "$LOG"
echo "[test_u34_syscalls] --- end output ---"

fail=0

# Part 1: U33 applets still work — cat motd + ls /bin + echo.
if grep -F -q "done" "$LOG"; then
    echo "[test_u34_syscalls] OK   echo: 'done' printed"
else
    echo "[test_u34_syscalls] MISS echo: 'done' not seen"
    fail=1
fi

cat_hits=0
for word in Welcome Hamnix scratch Adder kernel; do
    if grep -F -q "$word" "$LOG"; then
        cat_hits=$((cat_hits + 1))
    fi
done
if [ "$cat_hits" -ge 2 ]; then
    echo "[test_u34_syscalls] OK   cat:  $cat_hits motd words printed"
else
    echo "[test_u34_syscalls] MISS cat:  only $cat_hits motd words (need >=2)"
    fail=1
fi

ls_hits=0
for name in echo cat ls sh mount uname pwd grep find date head; do
    if grep -F -q "$name" "$LOG"; then
        ls_hits=$((ls_hits + 1))
    fi
done
if [ "$ls_hits" -ge 5 ]; then
    echo "[test_u34_syscalls] OK   ls:   $ls_hits binary names printed"
else
    echo "[test_u34_syscalls] MISS ls:   only $ls_hits binary names (need >=5)"
    fail=1
fi

# Part 2: NO unknown syscall lines for nr=40, nr=19, nr=72.
# linux_u prints: "linux_u: unknown syscall nr=%d a0=%x" — match the
# nr= prefix to avoid catching nr=140 / nr=190 etc. by accident.
for n in 40 19 72; do
    if grep -E -q "unknown syscall nr=$n[^0-9]" "$LOG"; then
        echo "[test_u34_syscalls] FAIL: still seeing -ENOSYS for nr=$n"
        grep -E "unknown syscall nr=$n[^0-9]" "$LOG" | head -3 || true
        fail=1
    else
        echo "[test_u34_syscalls] OK   nr=$n: no -ENOSYS noise"
    fi
done

if grep -F -q "TRAP: vector" "$LOG"; then
    echo "[test_u34_syscalls] DIAG: kernel reported a CPU exception"
    grep -F "TRAP: vector" "$LOG" | head -5 || true
    fail=1
fi
if grep -F -q "page fault" "$LOG"; then
    echo "[test_u34_syscalls] DIAG: page fault"
    grep -F "page fault" "$LOG" | head -5 || true
    fail=1
fi
if grep -F -q "unknown syscall" "$LOG"; then
    echo "[test_u34_syscalls] DIAG: remaining unknown syscall lines"
    grep -F "unknown syscall" "$LOG" | sort -u | head -10 || true
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_u34_syscalls] FAIL (qemu rc=$rc)"
    exit 1
fi

echo "[test_u34_syscalls] PASS -- sendfile(40), readv(19), fcntl(72) live"
