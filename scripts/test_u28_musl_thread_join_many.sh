#!/usr/bin/env bash
# scripts/test_u28_musl_thread_join_many.sh -- U28 stress fixture.
#
# N workers, each doing mmap+write+munmap loops. Validates fd-table
# sharing and per-thread state isolation across the CLONE_VM|
# CLONE_FILES path.
#
# PASS criteria: 4 "U28: jthread N done" markers (N=1..4) plus the
# final "U28: jcounter=4 (expect 4)".

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

UBIN=tests/u-binary/u_musl_thread_join_many

if [ ! -f "$UBIN" ]; then
    echo "[test_u28_musl_thread_join_many] SKIP: $UBIN not staged"
    echo "    apt-get install -y musl-tools  # (needs sudo)"
    echo "    then: make -C tests/u-binary/src/musl_thread_join_many install"
    exit 0
fi

ELF=build/hamnix-vmlinux.elf
HAMSH_ELF=build/user/hamsh.elf

echo "[test_u28_musl_thread_join_many] (1/4) Build userland"
bash scripts/build_user.sh
bash scripts/build_modules.sh

echo "[test_u28_musl_thread_join_many] (2/4) Swap /init + embed binary"
HAMNIX_EMBED_UBIN=1 INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py

echo "[test_u28_musl_thread_join_many] (3/4) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF"

echo "[test_u28_musl_thread_join_many] (4/4) Boot QEMU + run binary"
LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null' EXIT

set +e
(
    sleep 3
    printf 'u_musl_thread_join_many\n'
    sleep 15
    printf 'exit\n'
    sleep 1
) | timeout 50s qemu-system-x86_64 \
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

echo "[test_u28_musl_thread_join_many] --- captured output ---"
cat "$LOG"
echo "[test_u28_musl_thread_join_many] --- end output ---"

fail=0

check_marker() {
    local label="$1"
    local needle="$2"
    if grep -F -q "$needle" "$LOG"; then
        echo "[test_u28_musl_thread_join_many] OK: $label  ('$needle')"
    else
        echo "[test_u28_musl_thread_join_many] MISS: $label  ('$needle')"
        fail=1
    fi
}

for i in 1 2 3 4; do
    check_marker "jthread $i done" "U28: jthread $i done"
done
check_marker "jcounter=4" "U28: jcounter=4 (expect 4)"

if grep -F -q "unknown syscall" "$LOG"; then
    echo "[test_u28_musl_thread_join_many] DIAG: unknown syscall(s)"
    grep -F "unknown syscall" "$LOG" | sort -u || true
fi
if grep -F -q "TRAP: vector" "$LOG"; then
    echo "[test_u28_musl_thread_join_many] DIAG: CPU exception"
    grep -F "TRAP: vector" "$LOG" | head -5 || true
fi
if grep -F -q "mmap table full" "$LOG"; then
    echo "[test_u28_musl_thread_join_many] DIAG: mmap table full"
fi
if grep -F -q "MISMATCH" "$LOG"; then
    echo "[test_u28_musl_thread_join_many] DIAG: per-thread page mismatch"
    grep -F "MISMATCH" "$LOG" | head -5 || true
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_u28_musl_thread_join_many] FAIL (qemu rc=$rc)"
    exit 1
fi

echo "[test_u28_musl_thread_join_many] PASS -- N-thread mmap loop + fd-table share"
