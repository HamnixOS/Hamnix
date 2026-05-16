#!/usr/bin/env bash
# scripts/test_u18_glibc_hello.sh -- U18 milestone: first glibc-static
# C binary attempted on Hamnix.
#
# Boots Hamnix with /bin/u_glibc_hello embedded in the initramfs and
# drives hamsh to exec it. u_glibc_hello is a host-built,
# glibc-static, OSABI=Linux x86_64 ELF compiled with stock `cc
# -static -O2`. Unlike U12's musl static-PIE binary (whose _start
# touches only arch_prctl/set_tid_address/brk/writev), glibc-static
# drags in a much heavier startup: TLS bring-up, rseq registration,
# set_robust_list, sigaction/sigprocmask table install, mprotect,
# and the usual brk/mmap/uname.
#
# The whole point of U18 is to expose the *next* gap: an unknown
# syscall, an invalid opcode, or a #GP. The test asserts the
# success marker on serial but is expected to FAIL initially; the
# captured kernel log is the deliverable.
#
# REQUIRES: a host C compiler plus glibc's static archive (libc.a).
# If tests/u-binary/u_glibc_hello hasn't been staged (because the
# host build skipped), exit 0 with a clear note so CI without the
# host toolchain still passes.

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

UBIN=tests/u-binary/u_glibc_hello
if [ ! -f "$UBIN" ]; then
    echo "[test_u18_glibc_hello] SKIP: $UBIN not staged"
    echo "    REQUIRES host cc + libc6-dev (static glibc)."
    echo "    apt-get install -y libc6-dev  # (needs sudo)"
    echo "    then: make -C tests/u-binary/src/glibc_hello install"
    exit 0
fi

ELF=build/hamnix-vmlinux.elf
HAMSH_ELF=build/user/hamsh.elf

echo "[test_u18_glibc_hello] (1/4) Build userland (hamsh + helpers)"
bash scripts/build_user.sh
bash scripts/build_modules.sh

echo "[test_u18_glibc_hello] (2/4) Swap /init = $HAMSH_ELF + embed u_glibc_hello"
INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py

echo "[test_u18_glibc_hello] (3/4) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF"

echo "[test_u18_glibc_hello] (4/4) Boot QEMU + run /bin/u_glibc_hello via hamsh"
LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null' EXIT

set +e
(
    sleep 3
    printf 'u_glibc_hello\n'
    sleep 4
    printf 'exit\n'
    sleep 1
) | timeout 25s qemu-system-x86_64 \
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

echo "[test_u18_glibc_hello] --- captured output ---"
cat "$LOG"
echo "[test_u18_glibc_hello] --- end output ---"

fail=0

check_marker() {
    local label="$1"
    local needle="$2"
    if grep -F -q "$needle" "$LOG"; then
        echo "[test_u18_glibc_hello] OK: $label  ('$needle')"
    else
        echo "[test_u18_glibc_hello] MISS: $label  ('$needle')"
        fail=1
    fi
}

# Primary success criterion: glibc's crt1 + __libc_start_main ran
# the whole way through against Hamnix's syscall surface and
# printf("U18: glibc static hello\n") flushed to serial.
check_marker "glibc main() reached serial" "U18: glibc static hello"
# Secondary: the U1 ELF-detect path noticed the OSABI=Linux byte.
check_marker "U1/U2 ELF detect"            "Linux-ABI binary detected"

# Diagnostics: surface the next-gap signal for parent triage.
if grep -F -q "unknown syscall" "$LOG"; then
    echo "[test_u18_glibc_hello] DIAG: kernel logged 'unknown syscall' --" \
         "glibc exercised a syscall Hamnix doesn't handle yet."
    grep -F "unknown syscall" "$LOG" | sort -u || true
fi
if grep -F -q "TRAP: vector" "$LOG"; then
    echo "[test_u18_glibc_hello] DIAG: kernel reported a CPU exception" \
         "-- check vector + RIP for user-mode fault site."
    grep -F "TRAP: vector" "$LOG" | head -5 || true
fi
if grep -F -q "ENOSYS" "$LOG"; then
    echo "[test_u18_glibc_hello] DIAG: -ENOSYS surfaced -- check which nr."
    grep -F "ENOSYS" "$LOG" | head -5 || true
fi
if grep -F -q "linux_u:" "$LOG"; then
    echo "[test_u18_glibc_hello] DIAG: linux_u trace lines"
    grep -F "linux_u:" "$LOG" | head -20 || true
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_u18_glibc_hello] FAIL (qemu rc=$rc) -- expected at first" \
         "run; inspect the diag block above for the next gap."
    exit 1
fi

echo "[test_u18_glibc_hello] PASS -- first glibc-static C binary ran on Hamnix"
