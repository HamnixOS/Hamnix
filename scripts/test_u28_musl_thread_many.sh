#!/usr/bin/env bash
# scripts/test_u28_musl_thread_many.sh -- U28 stress fixture.
#
# Eight workers each bump a shared counter 1000 times under a mutex.
# Validates that the runqueue scales (NTASKS=16 covers 11 live tasks
# at peak) and that the futex wait queue handles many concurrent
# waiters on the same address.
#
# PASS criteria: all eight "U28: thread N done" markers (N=1..8) plus
# the final "U28: counter=8000 (expect 8000)".

. "$(dirname "$0")/_build_lock.sh"
. "$(dirname "$0")/_ensure_ubin.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

UBIN=tests/u-binary/u_musl_thread_many
# Build-on-missing: the fixture is gitignored (host-built). If absent,
# build it from tests/u-binary/src/musl_thread_many; only SKIP on a
# real failure (e.g. a genuine missing musl-gcc).
ensure_ubin_or_skip test_u28_musl_thread_many u_musl_thread_many musl_thread_many

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf

echo "[test_u28_musl_thread_many] (1/4) Build userland"
bash scripts/build_user.sh
bash scripts/build_modules.sh

echo "[test_u28_musl_thread_many] (2/4) Swap /init + embed u_musl_thread_many"
HAMNIX_EMBED_UBIN=1 INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py

echo "[test_u28_musl_thread_many] (3/4) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF"

echo "[test_u28_musl_thread_many] (4/4) Boot QEMU + run u_musl_thread_many"
LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null' EXIT

set +e
(
    sleep 3
    printf 'u_musl_thread_many\n'
    sleep 25
    printf 'exit\n'
    sleep 1
) | timeout 60s qemu-system-x86_64 \
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

echo "[test_u28_musl_thread_many] --- captured output ---"
cat "$LOG"
echo "[test_u28_musl_thread_many] --- end output ---"

fail=0

check_marker() {
    local label="$1"
    local needle="$2"
    if grep -F -q "$needle" "$LOG"; then
        echo "[test_u28_musl_thread_many] OK: $label  ('$needle')"
    else
        echo "[test_u28_musl_thread_many] MISS: $label  ('$needle')"
        fail=1
    fi
}

for i in 1 2 3 4 5 6 7 8; do
    check_marker "thread $i done" "U28: thread $i done"
done
check_marker "counter=8000" "U28: counter=8000 (expect 8000)"

if grep -F -q "unknown syscall" "$LOG"; then
    echo "[test_u28_musl_thread_many] DIAG: unknown syscall(s) logged"
    grep -F "unknown syscall" "$LOG" | sort -u || true
fi
if grep -F -q "TRAP: vector" "$LOG"; then
    echo "[test_u28_musl_thread_many] DIAG: kernel reported a CPU exception"
    grep -F "TRAP: vector" "$LOG" | head -5 || true
fi
if grep -F -q "mmap table full" "$LOG"; then
    echo "[test_u28_musl_thread_many] DIAG: mmap table full"
    grep -F "mmap table full" "$LOG" | head -5 || true
fi
if grep -F -q "no free task slot" "$LOG"; then
    echo "[test_u28_musl_thread_many] DIAG: task table full"
    grep -F "no free task slot" "$LOG" | head -5 || true
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_u28_musl_thread_many] FAIL (qemu rc=$rc)"
    exit 1
fi

echo "[test_u28_musl_thread_many] PASS -- 8 threads x 1000 iters under one mutex"
