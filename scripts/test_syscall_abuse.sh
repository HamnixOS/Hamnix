#!/usr/bin/env bash
# scripts/test_syscall_abuse.sh — syscall-boundary security audit.
#
# Fires a set of deliberately malformed syscalls (kernel-space pointer,
# NULL pointer, wild/unmapped pointer, overflow length) and asserts the
# kernel REJECTS each with an error code rather than panicking or
# reading/writing kernel memory.
#
# Pipeline:
#   1. Build userland (hamsh + coreutils).
#   2. Build tests/test_syscall_abuse.ad -> build/user/test_syscall_abuse.elf.
#   3. Plant /init = hamsh.elf.
#   4. Rebuild the kernel image.
#   5. Boot in QEMU, drive /bin/test_syscall_abuse via hamsh, exit.
#   6. Grep serial log for [syscall_abuse] markers + final PASS.
#
# PASS sentinel: "[syscall_abuse] PASS"
#
# The test also asserts NO kernel exception (TRAP: vector / page fault /
# triple fault) occurred during the run — proving the kernel KEEPS
# RUNNING after all the abusive calls.

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf
TEST_ELF=build/user/test_syscall_abuse.elf

echo "[test_syscall_abuse] (1/5) Build userland (hamsh + coreutils)"
bash scripts/build_user.sh >/dev/null
bash scripts/build_modules.sh >/dev/null

echo "[test_syscall_abuse] (2/5) Build tests/test_syscall_abuse.ad -> $TEST_ELF"
mkdir -p build/user
python3 -m compiler.adder compile \
    --target=x86_64-adder-user \
    tests/test_syscall_abuse.ad \
    -o "$TEST_ELF"

echo "[test_syscall_abuse] (3/5) Plant /init = hamsh + /bin/test_syscall_abuse in cpio"
INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py >/dev/null

echo "[test_syscall_abuse] (4/5) Rebuild kernel image"
mkdir -p build
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

echo "[test_syscall_abuse] (5/5) Boot QEMU + drive the abuse test via hamsh"
LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null' EXIT

set +e
(
    sleep 20
    printf '/bin/test_syscall_abuse\n'
    sleep 8
    printf 'exit\n'
    sleep 2
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

echo "[test_syscall_abuse] --- captured output ---"
cat "$LOG"
echo "[test_syscall_abuse] --- end output ---"

fail=0

check_marker() {
    local marker="$1"
    local label="$2"
    if grep -F -q "$marker" "$LOG"; then
        echo "[test_syscall_abuse] OK: $label"
    else
        echo "[test_syscall_abuse] MISS: $label (expected '$marker')" >&2
        fail=1
    fi
}

# Individual test cases.
check_marker "[syscall_abuse] T1 PASS" "kernel-ptr read rejected"
check_marker "[syscall_abuse] T2 PASS" "null-ptr write rejected"
check_marker "[syscall_abuse] T3 PASS" "wild-ptr open rejected"
check_marker "[syscall_abuse] T4 PASS" "overflow-len read rejected"
check_marker "[syscall_abuse] T5 PASS" "huge-len write rejected"
check_marker "[syscall_abuse] T6 PASS" "null-fds pipe rejected"
check_marker "[syscall_abuse] T7 PASS" "kernel-ptr getcwd rejected"
check_marker "[syscall_abuse] T8 PASS" "kernel-ptr write rejected"
check_marker "[syscall_abuse] T9 PASS" "kernel-ptr open path rejected"
check_marker "[syscall_abuse] T10 PASS" "near-top-overrun read rejected"

# Final sentinel.
check_marker "[syscall_abuse] PASS" "all abuse cases passed"

# No CPU exception / kernel panic during the run.
if grep -a -q -E "TRAP: vector|page fault|triple fault|kernel panic" "$LOG"; then
    echo "[test_syscall_abuse] FAIL: CPU exception or kernel panic observed:" >&2
    grep -a -E "TRAP: vector|page fault|triple fault|kernel panic" "$LOG" | head -5 >&2
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_syscall_abuse] FAIL (qemu rc=$rc)" >&2
    exit 1
fi

echo "[test_syscall_abuse] PASS — kernel correctly rejects all malformed syscall args"
exit 0
