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

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

UBIN_PARENT=tests/u-binary/u_glibc_exec
UBIN_CHILD=tests/u-binary/u_glibc_hello

if [ ! -f "$UBIN_PARENT" ]; then
    echo "[test_u25_exec] SKIP: $UBIN_PARENT not staged"
    echo "    REQUIRES host cc + libc6-dev (static glibc)."
    echo "    apt-get install -y libc6-dev  # (needs sudo)"
    echo "    then: make -C tests/u-binary/src/glibc_exec install"
    exit 0
fi
if [ ! -f "$UBIN_CHILD" ]; then
    echo "[test_u25_exec] SKIP: $UBIN_CHILD not staged (parent execs into it)"
    echo "    then: make -C tests/u-binary/src/glibc_hello install"
    exit 0
fi

ELF=build/hamnix-vmlinux.elf
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
(
    sleep 3
    printf 'u_glibc_exec\n'
    sleep 5
    printf 'exit\n'
    sleep 1
) | timeout 30s qemu-system-x86_64 \
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

echo "[test_u25_exec] --- captured output ---"
cat "$LOG"
echo "[test_u25_exec] --- end output ---"

fail=0

check_marker() {
    local label="$1"
    local needle="$2"
    if grep -F -q "$needle" "$LOG"; then
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
if grep -F -q "unknown syscall" "$LOG"; then
    echo "[test_u25_exec] DIAG: kernel logged 'unknown syscall'"
    grep -F "unknown syscall" "$LOG" | sort -u || true
fi
if grep -F -q "TRAP: vector" "$LOG"; then
    echo "[test_u25_exec] DIAG: kernel reported a CPU exception"
    grep -F "TRAP: vector" "$LOG" | head -5 || true
fi
if grep -F -q "execve" "$LOG"; then
    echo "[test_u25_exec] DIAG: execve trace lines"
    grep -F "execve" "$LOG" | head -10 || true
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_u25_exec] FAIL (qemu rc=$rc)"
    exit 1
fi

echo "[test_u25_exec] PASS -- Linux ELF -> Linux ELF execve chain works"
