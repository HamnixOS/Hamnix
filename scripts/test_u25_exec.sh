#!/usr/bin/env bash
# scripts/test_u25_exec.sh -- U25 milestone: a Linux ELF spawns
# another Linux ELF via SYS_execve(59).
#
# Boots Hamnix with /bin/u_glibc_exec embedded in the initramfs and
# drives hamsh to exec it. u_glibc_exec is a host-built static-PIE
# OSABI=Linux x86_64 ELF whose main() does:
#
#     printf("U25: parent before execve\n");
#     execve("/bin/u_glibc_hello", argv, environ);
#
# /bin/u_glibc_hello is the U18 fixture already in the initramfs and
# prints "U18: glibc static hello".
#
# PASS criteria: BOTH markers land on serial. If SYS_execve still
# returns -ENOSYS (or the new image faults during bring-up) only the
# parent marker shows up and we fail.
#
# Skip-on-missing: if tests/u-binary/u_glibc_exec hasn't been built
# on the host, exit 0 with a notice -- matches the U18/U19/U22
# convention so CI without libc6-dev keeps moving.
#
# REQUIRES: host cc + libc6-dev. Build steps:
#     make -C tests/u-binary/src/glibc_hello install
#     make -C tests/u-binary/src/glibc_exec  install

. "$(dirname "$0")/_build_lock.sh"
. "$(dirname "$0")/_qemu_drive.sh"
. "$(dirname "$0")/_ensure_ubin.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

UBIN_PARENT=tests/u-binary/u_glibc_exec
UBIN_CHILD=tests/u-binary/u_glibc_hello

# Build-on-missing: both fixtures are gitignored (host-built). The
# parent execs into the child, so both must be present. Build each
# from its src recipe; only SKIP if a build genuinely fails.
ensure_ubin_or_skip test_u25_exec u_glibc_exec  glibc_exec
ensure_ubin_or_skip test_u25_exec u_glibc_hello glibc_hello

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf

echo "[test_u25_exec] (1/4) Build userland (hamsh + helpers)"
bash scripts/build_user.sh
bash scripts/build_modules.sh

echo "[test_u25_exec] (2/4) Swap /init = $HAMSH_ELF + embed u_glibc_exec"
HAMNIX_EMBED_UBIN=1 INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py

echo "[test_u25_exec] (3/4) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF"

echo "[test_u25_exec] (4/4) Boot QEMU + run /bin/u_glibc_exec via hamsh"
LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null' EXIT

set +e
# Prompt-aware drive: wait for hamsh's ready banner before sending input
# (a fixed sleep races boot-time variance -- see _qemu_drive.sh).
qemu_drive "$LOG" "$ELF" "[hamsh] M16.35 shell ready" 30 \
    -- "u_glibc_exec" 5 \
       "exit" 1
rc="$QEMU_DRIVE_RC"
set -e

echo "[test_u25_exec] --- captured output ---"
cat "$LOG"
echo "[test_u25_exec] --- end output ---"

fail=0

check_marker() {
    local label="$1"
    local needle="$2"
    if grep -a -F -q "$needle" "$LOG"; then
        echo "[test_u25_exec] OK: $label  ('$needle')"
    else
        echo "[test_u25_exec] MISS: $label  ('$needle')"
        fail=1
    fi
}

# Both markers must land. Parent prints before execve; child only
# runs if the kernel SYSRETd into the new image successfully.
check_marker "parent ran"     "U25: parent before execve"
check_marker "execve landed"  "U18: glibc static hello"

# Diagnostics: surface the next-gap signal for triage.
if grep -a -F -q "unknown syscall" "$LOG"; then
    echo "[test_u25_exec] DIAG: kernel logged 'unknown syscall'"
    grep -a -F "unknown syscall" "$LOG" | sort -u || true
fi
if grep -a -F -q "TRAP: vector" "$LOG"; then
    echo "[test_u25_exec] DIAG: kernel reported a CPU exception"
    grep -a -F "TRAP: vector" "$LOG" | head -5 || true
fi
if grep -a -F -q "execve" "$LOG"; then
    echo "[test_u25_exec] DIAG: execve trace lines"
    grep -a -F "execve" "$LOG" | head -10 || true
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_u25_exec] FAIL (qemu rc=$rc)"
    exit 1
fi

echo "[test_u25_exec] PASS -- Linux ELF -> Linux ELF execve chain works"
