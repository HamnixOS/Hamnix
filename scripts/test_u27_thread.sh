#!/usr/bin/env bash
# scripts/test_u27_thread.sh -- U27 milestone: a Linux ELF spawns two
# pthreads via clone(CLONE_VM|CLONE_THREAD|...), each bumps a shared
# counter under a mutex, the main thread joins both and validates the
# total.
#
# Exercises the pthread_create -> clone(CLONE_VM|CLONE_THREAD|
# CLONE_FS|CLONE_FILES|CLONE_SIGHAND|CLONE_SETTLS|CLONE_PARENT_SETTID|
# CLONE_CHILD_CLEARTID|CLONE_SYSVSEM) path AND the pthread_join ->
# FUTEX_WAIT-on-tid path (woken when task_exit_current clears the
# CLONE_CHILD_CLEARTID slot). Boots Hamnix with /bin/u_glibc_thread
# embedded and drives hamsh to run it.
#
# PASS criteria: all three markers land on serial:
#   - "U27: thread 1 done"
#   - "U27: thread 2 done"
#   - "U27: counter=200 (expect 200)"
#
# Skip-on-missing: if tests/u-binary/u_glibc_thread hasn't been built
# on the host, exit 0 with a notice -- matches the U18..U26 fixture
# convention so CI without libc6-dev keeps moving.
#
# REQUIRES: host cc + libc6-dev (static glibc + static libpthread).
# Build step:
#     make -C tests/u-binary/src/glibc_thread install

. "$(dirname "$0")/_build_lock.sh"
. "$(dirname "$0")/_qemu_drive.sh"
. "$(dirname "$0")/_ensure_ubin.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

UBIN=tests/u-binary/u_glibc_thread
# Build-on-missing: the fixture is gitignored (host-built). If absent,
# build it from tests/u-binary/src/glibc_thread; only SKIP on a real
# failure (e.g. a genuine missing static glibc + libpthread).
ensure_ubin_or_skip test_u27_thread u_glibc_thread glibc_thread

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf

echo "[test_u27_thread] (1/4) Build userland (hamsh + helpers)"
bash scripts/build_user.sh
bash scripts/build_modules.sh

echo "[test_u27_thread] (2/4) Swap /init = $HAMSH_ELF + embed u_glibc_thread"
HAMNIX_EMBED_UBIN=1 INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py

echo "[test_u27_thread] (3/4) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF"

echo "[test_u27_thread] (4/4) Boot QEMU + run /bin/u_glibc_thread via hamsh"
LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null' EXIT

set +e
# Prompt-aware drive: wait for hamsh's ready banner before sending input
# (a fixed sleep races boot-time variance -- see _qemu_drive.sh).
qemu_drive "$LOG" "$ELF" "[hamsh] M16.35 shell ready" 40 \
    -- "u_glibc_thread" 8 \
       "exit" 1
rc="$QEMU_DRIVE_RC"
set -e

echo "[test_u27_thread] --- captured output ---"
cat "$LOG"
echo "[test_u27_thread] --- end output ---"

fail=0

check_marker() {
    local label="$1"
    local needle="$2"
    if grep -a -F -q "$needle" "$LOG"; then
        echo "[test_u27_thread] OK: $label  ('$needle')"
    else
        echo "[test_u27_thread] MISS: $label  ('$needle')"
        fail=1
    fi
}

check_marker "thread 1 done"     "U27: thread 1 done"
check_marker "thread 2 done"     "U27: thread 2 done"
check_marker "counter=200"       "U27: counter=200 (expect 200)"

# Diagnostics: surface the next-gap signal for triage.
if grep -a -F -q "unknown syscall" "$LOG"; then
    echo "[test_u27_thread] DIAG: kernel logged 'unknown syscall'"
    grep -a -F "unknown syscall" "$LOG" | sort -u || true
fi
if grep -a -F -q "TRAP: vector" "$LOG"; then
    echo "[test_u27_thread] DIAG: kernel reported a CPU exception"
    grep -a -F "TRAP: vector" "$LOG" | head -5 || true
fi
if grep -a -F -q "linux_u:" "$LOG"; then
    echo "[test_u27_thread] DIAG: linux_u trace lines"
    grep -a -F "linux_u:" "$LOG" | head -20 || true
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_u27_thread] FAIL (qemu rc=$rc)"
    exit 1
fi

echo "[test_u27_thread] PASS -- pthread_create + mutex + join works"
