#!/usr/bin/env bash
# scripts/test_u27_musl_thread.sh -- U27 pivot fixture (musl threads).
#
# After U27's first agent got stuck guessing FUTEX_WAIT return values
# against glibc's thicker pthread machinery, the pivot is to validate
# the kernel's CLONE_THREAD path with musl's much-simpler pthread
# implementation. musl rolls pthread into libc and goes straight from
# pthread_create into clone() without the glibc late_init/SIGSETXID/
# __libc_single_threaded_internal dance.
#
# Two workers each bump a shared counter 100 times under a mutex; the
# main thread joins both and reports the total.
#
# PASS criteria: all three markers land on serial:
#   - "U27: thread 1 done"
#   - "U27: thread 2 done"
#   - "U27: counter=200 (expect 200)"
#
# Skip-on-missing: if tests/u-binary/u_musl_thread hasn't been built
# on the host, exit 0 with a notice -- matches the U12..U26 fixture
# convention so CI without musl-tools keeps moving.
#
# REQUIRES: musl-gcc on $PATH. Build step:
#     make -C tests/u-binary/src/musl_thread install

. "$(dirname "$0")/_build_lock.sh"
. "$(dirname "$0")/_qemu_drive.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

UBIN=tests/u-binary/u_musl_thread

if [ ! -f "$UBIN" ]; then
    echo "[test_u27_musl_thread] SKIP: $UBIN not staged"
    echo "    REQUIRES musl-gcc on the host."
    echo "    apt-get install -y musl-tools  # (needs sudo)"
    echo "    then: make -C tests/u-binary/src/musl_thread install"
    exit 0
fi

ELF=build/hamnix-vmlinux.elf
HAMSH_ELF=build/user/hamsh.elf

echo "[test_u27_musl_thread] (1/4) Build userland (hamsh + helpers)"
bash scripts/build_user.sh
bash scripts/build_modules.sh

echo "[test_u27_musl_thread] (2/4) Swap /init = $HAMSH_ELF + embed u_musl_thread"
HAMNIX_EMBED_UBIN=1 INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py

echo "[test_u27_musl_thread] (3/4) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF"

echo "[test_u27_musl_thread] (4/4) Boot QEMU + run /bin/u_musl_thread via hamsh"
LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null' EXIT

# Prompt-aware drive: wait for hamsh's ready banner before sending
# input (a fixed sleep races boot-time variance — see _qemu_drive.sh).
set +e
qemu_drive "$LOG" "$ELF" "[hamsh] M16.35 shell ready" 45 \
    -- "u_musl_thread" 8 \
       "exit" 1
rc="$QEMU_DRIVE_RC"
set -e

echo "[test_u27_musl_thread] --- captured output ---"
cat "$LOG"
echo "[test_u27_musl_thread] --- end output ---"

fail=0

check_marker() {
    local label="$1"
    local needle="$2"
    if grep -F -q "$needle" "$LOG"; then
        echo "[test_u27_musl_thread] OK: $label  ('$needle')"
    else
        echo "[test_u27_musl_thread] MISS: $label  ('$needle')"
        fail=1
    fi
}

check_marker "thread 1 done"     "U27: thread 1 done"
check_marker "thread 2 done"     "U27: thread 2 done"
check_marker "counter=200"       "U27: counter=200 (expect 200)"

# Diagnostics: surface the next-gap signal for triage.
if grep -F -q "unknown syscall" "$LOG"; then
    echo "[test_u27_musl_thread] DIAG: kernel logged 'unknown syscall'"
    grep -F "unknown syscall" "$LOG" | sort -u || true
fi
if grep -F -q "TRAP: vector" "$LOG"; then
    echo "[test_u27_musl_thread] DIAG: kernel reported a CPU exception"
    grep -F "TRAP: vector" "$LOG" | head -5 || true
fi
if grep -F -q "linux_u:" "$LOG"; then
    echo "[test_u27_musl_thread] DIAG: linux_u trace lines"
    grep -F "linux_u:" "$LOG" | head -20 || true
fi
if grep -F -q "clone:" "$LOG"; then
    echo "[test_u27_musl_thread] DIAG: clone trace lines"
    grep -F "clone:" "$LOG" | head -20 || true
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_u27_musl_thread] FAIL (qemu rc=$rc)"
    exit 1
fi

echo "[test_u27_musl_thread] PASS -- musl pthread_create + mutex + join works"
