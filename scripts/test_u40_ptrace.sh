#!/usr/bin/env bash
# scripts/test_u40_ptrace.sh — #147 ptrace(2) + strace credibility.
#
# Boots Hamnix under QEMU and runs /bin/u_strace, a real ptrace-driven
# syscall tracer (tests/u-binary/src/strace/strace.c). The tracer forks
# a tracee that calls ptrace(PTRACE_TRACEME) then runs a small workload
# (two write()s + exit_group); the tracer loops
# waitpid + PTRACE_GETREGS + PTRACE_SYSCALL, decoding each syscall stop
# into a "TRACE: name(args) = ret" line on stderr.
#
# This exercises the WHOLE ptrace path end to end:
#   - PTRACE_TRACEME arms tracing on the child
#   - the kernel injects syscall-enter AND syscall-exit STOPs at the
#     Linux-ABI dispatch choke point (linux_abi/u_ptrace.ad)
#   - the tracer's waitpid observes them as WIFSTOPPED / SIGTRAP|0x80
#   - PTRACE_GETREGS returns the tracee's captured user_regs_struct
#   - PTRACE_SYSCALL single-steps syscall to syscall until the child exits
#
# PASS criteria (on serial, always grep -a — logs carry binary bytes):
#   - "strace: start"                  tracer ran
#   - "TRACE: write("                  a write() syscall was traced
#   - "TRACE: exit_group"              the child's exit was traced
#   - "strace: child exited"           the tracee exited and was reaped
#
# Build step (host needs musl-gcc):
#     make -C tests/u-binary/src/strace install
#
# NOTE: the host is slow TCG and load-sensitive — an rc=124 timeout is a
# spurious infra hiccup; the harness retries once. It is NOT a real
# failure.

. "$(dirname "$0")/_build_lock.sh"
. "$(dirname "$0")/_qemu_drive.sh"
. "$(dirname "$0")/_ensure_ubin.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

# Build-on-missing: u_strace is gitignored (host-built). If absent, build
# it from tests/u-binary/src/strace; only SKIP on a real toolchain gap.
ensure_ubin_or_skip test_u40_ptrace u_strace strace

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf

echo "[test_u40_ptrace] (1/4) Build userland (hamsh + helpers)"
bash scripts/build_user.sh
bash scripts/build_modules.sh

echo "[test_u40_ptrace] (2/4) Swap /init = $HAMSH_ELF + embed u_strace"
HAMNIX_EMBED_UBIN=1 INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py

echo "[test_u40_ptrace] (3/4) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF"

echo "[test_u40_ptrace] (4/4) Boot QEMU + run /bin/u_strace via hamsh"
LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null' EXIT

run_once() {
    set +e
    qemu_drive "$LOG" "$ELF" "[hamsh] M16.35 shell ready" 60 \
        -- "u_strace" 12 \
           "exit" 1
    QD_RC="$QEMU_DRIVE_RC"
    set -e
}

run_once
# Slow-TCG retry: a 124 timeout (or an empty log) is an infra hiccup,
# not a real failure — retry exactly once.
if [ "$QD_RC" -eq 124 ] || ! grep -a -q "strace: start" "$LOG"; then
    echo "[test_u40_ptrace] retrying once (rc=$QD_RC — slow-TCG hiccup)"
    : > "$LOG"
    run_once
fi

echo "[test_u40_ptrace] --- captured output ---"
cat "$LOG"
echo "[test_u40_ptrace] --- end output ---"

fail=0
check_marker() {
    local label="$1"
    local needle="$2"
    if grep -a -q "$needle" "$LOG"; then
        echo "[test_u40_ptrace] OK: $label  ('$needle')"
    else
        echo "[test_u40_ptrace] MISS: $label  ('$needle')"
        fail=1
    fi
}

check_marker "tracer started"     "strace: start"
check_marker "write() traced"     "TRACE: write("
check_marker "exit_group traced"  "TRACE: exit_group"
check_marker "child exited"       "strace: child exited"

# Diagnostics on failure.
if grep -a -q "ptrace:" "$LOG"; then
    echo "[test_u40_ptrace] DIAG: ptrace trace lines"
    grep -a "ptrace:" "$LOG" | head -10 || true
fi
if grep -a -q "TRACE:" "$LOG"; then
    echo "[test_u40_ptrace] DIAG: first TRACE lines"
    grep -a "TRACE:" "$LOG" | head -20 || true
fi
if grep -a -q "TRAP: vector" "$LOG"; then
    echo "[test_u40_ptrace] DIAG: kernel reported a CPU exception"
    grep -a "TRAP: vector" "$LOG" | head -5 || true
fi
if grep -a -q "unknown syscall" "$LOG"; then
    echo "[test_u40_ptrace] DIAG: kernel logged 'unknown syscall'"
    grep -a "unknown syscall" "$LOG" | sort -u | head || true
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_u40_ptrace] FAIL (qemu rc=$QD_RC)"
    exit 1
fi

echo "[test_u40_ptrace] PASS -- ptrace(2) + strace trace a Linux binary's syscalls"
