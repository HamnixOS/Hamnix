#!/usr/bin/env bash
# scripts/test_seccomp_native_user.sh — F10-8 / #457 NATIVE seccomp-lite
# END-TO-END userland test.
#
# Proves the userland arming surface (SYS_SECCOMP_NATIVE, nr=318) drives
# the per-task NATIVE allow-list bitmap (kernel/sched/core.ad
# seccomp_native_filter) AND that arch/x86/kernel/syscall.ad::do_syscall
# rejects denied native syscalls at entry with -EPERM.
#
# Complements scripts/test_seccomp_native.sh, which exercises the
# IN-KERNEL probe (seccomp_native_selftest) on a spare task slot via
# the accessors directly. This script exercises the USER-FACING path:
# a real ring-3 binary (build/user/test_seccomp_native_user.elf) calls
# the syscall, attempts denied nrs, and asserts each is bounced.
#
# Pipeline mirrors scripts/test_syscall_abuse.sh:
#   1. Build userland.
#   2. Build tests/test_seccomp_native_user.ad -> build/user/...elf.
#   3. Plant hamsh as /init (auto-installs /bin/<elfname>).
#   4. Rebuild kernel image.
#   5. Boot QEMU; drive /bin/test_seccomp_native_user via hamsh.
#   6. Grep serial log for the marker chain + final PASS.
#
# Pass marker: "[seccomp_native_user] PASS"
# Fail marker: any "[seccomp_native_user] FAIL"

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

export HAMNIX_BUILD_LOCK_TIMEOUT="${HAMNIX_BUILD_LOCK_TIMEOUT:-900}"

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf
TEST_ELF=build/user/test_seccomp_native_user.elf

LOG=${HAMNIX_SECCOMP_NATIVE_USER_LOG:-$(mktemp)}
trap 'INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1 || true' EXIT

echo "[test_seccomp_native_user] (1/5) Build userland"
bash scripts/build_user.sh >/dev/null

echo "[test_seccomp_native_user] (2/5) Build tests/test_seccomp_native_user.ad -> $TEST_ELF"
mkdir -p build/user
python3 -m compiler.adder compile \
    --target=x86_64-adder-user \
    tests/test_seccomp_native_user.ad \
    -o "$TEST_ELF"

echo "[test_seccomp_native_user] (3/5) Plant /init = hamsh + /bin/test_seccomp_native_user in cpio"
INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py >/dev/null

echo "[test_seccomp_native_user] (4/5) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

echo "[test_seccomp_native_user] (5/5) Boot QEMU + drive the test via hamsh"
set +e
(
    sleep 20
    printf '/bin/test_seccomp_native_user\n'
    sleep 5
    printf 'exit\n'
    sleep 2
) | timeout 90s qemu-system-x86_64 \
    -kernel "$ELF" \
    -smp 1 \
    -nographic \
    -no-reboot \
    -m 256M \
    -monitor none \
    -serial stdio \
    > "$LOG" 2>&1
rc=$?
set -e

echo "[test_seccomp_native_user] --- captured seccomp_native_user output ---"
grep -a -E "\[seccomp_native_user\]" "$LOG" || true
echo "[test_seccomp_native_user] --- end ---"

fail=0

check_marker() {
    local marker="$1"
    local label="$2"
    if grep -a -F -q "$marker" "$LOG"; then
        echo "[test_seccomp_native_user] OK: $label"
    else
        echo "[test_seccomp_native_user] MISS: $label (expected '$marker')" >&2
        fail=1
    fi
}

# Stage markers.
check_marker "[seccomp_native_user] T1 PASS" "pre-arm QUERY returns disarmed"
check_marker "[seccomp_native_user] T2 PASS" "pre-arm sys_write smoke"
check_marker "[seccomp_native_user] T3 PASS" "ARM with allow-list succeeds"
check_marker "[seccomp_native_user] T4 PASS" "denied SYS_PUTC bounced -EPERM"
check_marker "[seccomp_native_user] T5 PASS" "allowed SYS_GET_JIFFIES still works"
check_marker "[seccomp_native_user] T6 PASS" "denied SYS_CHDIR bounced -EPERM"
check_marker "[seccomp_native_user] T7 PASS" "re-arm rejected (irrevocable ratchet)"

# Final sentinel.
check_marker "[seccomp_native_user] PASS" "all userland seccomp-native cases passed"

# Any FAIL line is a fatal regression.
if grep -a -F -q "[seccomp_native_user] FAIL" "$LOG"; then
    echo "[test_seccomp_native_user] FAIL: in-test assertion failed:" >&2
    grep -a -F "[seccomp_native_user] FAIL" "$LOG" >&2 || true
    fail=1
fi

# Don't tolerate a CPU exception during the run — the gate must reject
# politely with -EPERM, NEVER fault the kernel.
if grep -a -q -E "TRAP: vector|page fault|triple fault|kernel panic" "$LOG"; then
    echo "[test_seccomp_native_user] FAIL: CPU exception or kernel panic observed:" >&2
    grep -a -E "TRAP: vector|page fault|triple fault|kernel panic" "$LOG" | head -5 >&2
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_seccomp_native_user] FAIL (qemu rc=$rc)" >&2
    exit 1
fi

echo "[test_seccomp_native_user] PASS — native seccomp-lite arms + enforces from userland"
exit 0
