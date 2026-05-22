#!/usr/bin/env bash
# scripts/test_u26_fork.sh -- U26 milestone: a Linux ELF fork()s a
# child, the child _exit(42)s, the parent waitpid()s and validates.
#
# Exercises the SIGCHLD/fork+wait pattern that glibc's system() /
# popen() / posix_spawn() all build on. Boots Hamnix with
# /bin/u_glibc_system embedded and drives hamsh to run it.
#
# PASS criteria: all three markers land on serial:
#   - "U26: parent before fork"
#   - "U26: child running"
#   - "U26: parent reaped child status=42"
#
# Skip-on-missing: if tests/u-binary/u_glibc_system hasn't been built
# on the host, exit 0 with a notice -- matches the U18..U25 fixture
# convention so CI without libc6-dev keeps moving.
#
# REQUIRES: host cc + libc6-dev. Build step:
#     make -C tests/u-binary/src/glibc_system install

. "$(dirname "$0")/_build_lock.sh"
. "$(dirname "$0")/_qemu_drive.sh"
. "$(dirname "$0")/_ensure_ubin.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

UBIN=tests/u-binary/u_glibc_system
# Build-on-missing: the fixture is gitignored (host-built). If absent,
# build it from tests/u-binary/src/glibc_system; only SKIP on a real
# failure (e.g. a genuine missing static glibc).
ensure_ubin_or_skip test_u26_fork u_glibc_system glibc_system

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf

echo "[test_u26_fork] (1/4) Build userland (hamsh + helpers)"
bash scripts/build_user.sh
bash scripts/build_modules.sh

echo "[test_u26_fork] (2/4) Swap /init = $HAMSH_ELF + embed u_glibc_system"
HAMNIX_EMBED_UBIN=1 INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py

echo "[test_u26_fork] (3/4) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF"

echo "[test_u26_fork] (4/4) Boot QEMU + run /bin/u_glibc_system via hamsh"
LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null' EXIT

# Prompt-aware drive: wait for hamsh's ready banner before sending
# input (a fixed sleep races boot-time variance — see _qemu_drive.sh).
set +e
qemu_drive "$LOG" "$ELF" "[hamsh] M16.35 shell ready" 45 \
    -- "u_glibc_system" 6 \
       "exit" 1
rc="$QEMU_DRIVE_RC"
set -e

echo "[test_u26_fork] --- captured output ---"
cat "$LOG"
echo "[test_u26_fork] --- end output ---"

fail=0

check_marker() {
    local label="$1"
    local needle="$2"
    if grep -F -q "$needle" "$LOG"; then
        echo "[test_u26_fork] OK: $label  ('$needle')"
    else
        echo "[test_u26_fork] MISS: $label  ('$needle')"
        fail=1
    fi
}

check_marker "parent before fork"  "U26: parent before fork"
check_marker "child ran"           "U26: child running"
check_marker "parent reaped"       "U26: parent reaped child status=42"

# Diagnostics: surface the next-gap signal for triage.
if grep -F -q "unknown syscall" "$LOG"; then
    echo "[test_u26_fork] DIAG: kernel logged 'unknown syscall'"
    grep -F "unknown syscall" "$LOG" | sort -u || true
fi
if grep -F -q "TRAP: vector" "$LOG"; then
    echo "[test_u26_fork] DIAG: kernel reported a CPU exception"
    grep -F "TRAP: vector" "$LOG" | head -5 || true
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_u26_fork] FAIL (qemu rc=$rc)"
    exit 1
fi

echo "[test_u26_fork] PASS -- Linux ELF fork+waitpid chain works"
