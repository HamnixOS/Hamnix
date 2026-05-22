#!/usr/bin/env bash
# scripts/test_u29_syscalls.sh -- U29 pipe2 / dup3 / getdents64 fixture.
#
# Drives u_musl_syscalls (a musl-built static-PIE binary that fires raw
# inline syscalls 293 / 292 / 217) and asserts the four expected marker
# lines on serial. Validates that linux_u_syscall_dispatch's new ladder
# entries are reachable and that the forwarding handlers return the
# values Linux promises (forwarded vfs_pipe rc, EINVAL for dup3(fd,fd),
# newfd for dup3 distinct, ENOTDIR for getdents64 on a non-dir fd).
#
# PASS criteria: all four "U29:" marker lines present in the captured
# qemu transcript.

. "$(dirname "$0")/_build_lock.sh"
. "$(dirname "$0")/_ensure_ubin.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

UBIN=tests/u-binary/u_musl_syscalls
# Build-on-missing: the fixture is gitignored (host-built). If absent,
# build it from tests/u-binary/src/musl_syscalls; only SKIP on a real
# failure (e.g. a genuine missing musl-gcc).
ensure_ubin_or_skip test_u29_syscalls u_musl_syscalls musl_syscalls

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf

echo "[test_u29_syscalls] (1/4) Build userland"
bash scripts/build_user.sh
bash scripts/build_modules.sh

echo "[test_u29_syscalls] (2/4) Swap /init + embed u_musl_syscalls"
HAMNIX_EMBED_UBIN=1 INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py

echo "[test_u29_syscalls] (3/4) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF"

echo "[test_u29_syscalls] (4/4) Boot QEMU + run u_musl_syscalls"
LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null' EXIT

set +e
(
    sleep 3
    printf 'u_musl_syscalls\n'
    sleep 6
    printf 'exit\n'
    sleep 1
) | timeout 35s qemu-system-x86_64 \
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

echo "[test_u29_syscalls] --- captured output ---"
cat "$LOG"
echo "[test_u29_syscalls] --- end output ---"

fail=0

check_marker() {
    local label="$1"
    local needle="$2"
    if grep -F -q "$needle" "$LOG"; then
        echo "[test_u29_syscalls] OK: $label  ('$needle')"
    else
        echo "[test_u29_syscalls] MISS: $label  ('$needle')"
        fail=1
    fi
}

check_marker "pipe2 rc=0"        "U29: pipe2 rc=0"
check_marker "dup3 same-fd"      "U29: dup3 same-fd rc=-22"
check_marker "dup3 distinct"     "U29: dup3 distinct rc=5"
check_marker "getdents64 ENOTDIR" "U29: getdents64 rc=-20"

if grep -F -q "unknown syscall" "$LOG"; then
    echo "[test_u29_syscalls] DIAG: unknown syscall(s) logged"
    grep -F "unknown syscall" "$LOG" | sort -u | head -10 || true
    fail=1
fi
if grep -F -q "TRAP: vector" "$LOG"; then
    echo "[test_u29_syscalls] DIAG: kernel reported a CPU exception"
    grep -F "TRAP: vector" "$LOG" | head -5 || true
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_u29_syscalls] FAIL (qemu rc=$rc)"
    exit 1
fi

echo "[test_u29_syscalls] PASS -- pipe2 / dup3 / getdents64 wired through"
