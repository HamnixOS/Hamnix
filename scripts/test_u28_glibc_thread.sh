#!/usr/bin/env bash
# scripts/test_u28_glibc_thread.sh -- U28 fixture (glibc threads).
#
# Extends U27's musl pthread plumbing to glibc's static-pie pthread.
# glibc takes a thicker path through __pthread_initialize_minimal +
# late_init (sigaction(SIGSETXID), rt_sigprocmask) and may prefer
# clone3 over clone on modern releases. The U28 kernel/ABI work
# tolerates -ENOSYS on the signal stubs and forwards clone3 to
# do_clone via _u_clone3.
#
# Two workers each bump a shared counter 100 times under a mutex;
# the main thread joins both and reports the total.
#
# PASS criteria: all three markers land on serial:
#   - "U27: thread 1 done"
#   - "U27: thread 2 done"
#   - "U27: counter=200 (expect 200)"
# (markers reuse the U27 strings because the fixture body matches.)
#
# Skip-on-missing: if tests/u-binary/u_glibc_thread hasn't been built
# on the host, exit 0 with a notice. REQUIRES static-pie glibc +
# libpthread.a.

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

UBIN=tests/u-binary/u_glibc_thread

if [ ! -f "$UBIN" ]; then
    echo "[test_u28_glibc_thread] SKIP: $UBIN not staged"
    echo "    REQUIRES static-pie glibc + libpthread.a on the host."
    echo "    apt-get install -y libc6-dev  # (needs sudo)"
    echo "    then: make -C tests/u-binary/src/glibc_thread install"
    exit 0
fi

ELF=build/hamnix-vmlinux.elf
HAMSH_ELF=build/user/hamsh.elf

echo "[test_u28_glibc_thread] (1/4) Build userland (hamsh + helpers)"
bash scripts/build_user.sh
bash scripts/build_modules.sh

echo "[test_u28_glibc_thread] (2/4) Swap /init = $HAMSH_ELF + embed u_glibc_thread"
INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py

echo "[test_u28_glibc_thread] (3/4) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF"

echo "[test_u28_glibc_thread] (4/4) Boot QEMU + run /bin/u_glibc_thread via hamsh"
LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null' EXIT

set +e
(
    sleep 3
    printf 'u_glibc_thread\n'
    sleep 12
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

echo "[test_u28_glibc_thread] --- captured output ---"
cat "$LOG"
echo "[test_u28_glibc_thread] --- end output ---"

fail=0

check_marker() {
    local label="$1"
    local needle="$2"
    if grep -F -q "$needle" "$LOG"; then
        echo "[test_u28_glibc_thread] OK: $label  ('$needle')"
    else
        echo "[test_u28_glibc_thread] MISS: $label  ('$needle')"
        fail=1
    fi
}

check_marker "thread 1 done"     "U27: thread 1 done"
check_marker "thread 2 done"     "U27: thread 2 done"
check_marker "counter=200"       "U27: counter=200 (expect 200)"

# Diagnostics: surface the next-gap signal for triage.
if grep -F -q "unknown syscall" "$LOG"; then
    echo "[test_u28_glibc_thread] DIAG: kernel logged 'unknown syscall'"
    grep -F "unknown syscall" "$LOG" | sort -u || true
fi
if grep -F -q "TRAP: vector" "$LOG"; then
    echo "[test_u28_glibc_thread] DIAG: kernel reported a CPU exception"
    grep -F "TRAP: vector" "$LOG" | head -5 || true
fi
if grep -F -q "linux_u:" "$LOG"; then
    echo "[test_u28_glibc_thread] DIAG: linux_u trace lines"
    grep -F "linux_u:" "$LOG" | head -20 || true
fi
if grep -F -q "clone:" "$LOG"; then
    echo "[test_u28_glibc_thread] DIAG: clone trace lines"
    grep -F "clone:" "$LOG" | head -20 || true
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_u28_glibc_thread] FAIL (qemu rc=$rc)"
    exit 1
fi

echo "[test_u28_glibc_thread] PASS -- glibc pthread_create + mutex + join works"
