#!/usr/bin/env bash
# scripts/test_coredump.sh -- #173 observability: ELF process core dumps.
#
# Proves the kernel writes a standard ELF ET_CORE file when a user task
# dies from an unhandled fatal fault signal. The kernel hook is
# kernel/core/coredump.ad's coredump_write_current(), invoked from
# kernel/sched/core.ad's deliver_fault_sigsegv() default-terminate branch
# BEFORE the task is torn down. The core lands at /tmp/core in tmpfs.
#
# End-to-end fixture (tests/u-binary/src/coredump/coredump.c):
#   - A forked child stamps 0xC0DEFACE into a writable global, then does
#     a NULL-pointer write -> SIGSEGV with NO handler -> kernel core-dump.
#   - The parent waitpid()s (asserts WIFSIGNALED && WTERMSIG == SIGSEGV),
#     re-opens /tmp/core and validates CONCRETE facts: ELF magic, e_type
#     == ET_CORE, e_machine == x86_64, a PT_LOAD whose dumped bytes at
#     &g_sentinel equal 0xC0DEFACE, and a PT_NOTE/NT_PRSTATUS whose RIP
#     is non-zero (the faulting instruction pointer).
#
# PASS criteria: all of these markers land on serial:
#   - "[coredump] module linked; fatal-sig table OK"   (boot gate)
#   - "[coredump] pid="                                (kernel wrote core)
#   - "COREDUMP: parent saw SIGSEGV child"
#   - "COREDUMP: core ET_CORE x86_64 ok"
#   - "COREDUMP: PT_LOAD sentinel match"
#   - "COREDUMP: NT_PRSTATUS rip ok"
#   - "COREDUMP: NT_PRPSINFO present"
#   - "COREDUMP: NT_AUXV present"
#   - "coredump: PASS"
#
# REQUIRES: musl-gcc on $PATH (build-on-missing via _ensure_ubin.sh).
#
# NOTE: a trailing QEMU rc=124 AFTER the markers have printed is benign
# (the kernel halts without powering off qemu, so the watchdog reaps it);
# the grep marker checks below are authoritative.

. "$(dirname "$0")/_build_lock.sh"
. "$(dirname "$0")/_qemu_drive.sh"
. "$(dirname "$0")/_ensure_ubin.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

UBIN=tests/u-binary/u_coredump
ensure_ubin_or_skip test_coredump u_coredump coredump

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf

echo "[test_coredump] (1/4) Build userland (hamsh + helpers)"
bash scripts/build_user.sh
bash scripts/build_modules.sh

echo "[test_coredump] (2/4) Swap /init = $HAMSH_ELF + embed u_coredump + sentinel"
HAMNIX_EMBED_UBIN=1 ENABLE_COREDUMP_TEST=1 INIT_ELF="$HAMSH_ELF" \
    python3 scripts/build_initramfs.py

echo "[test_coredump] (3/4) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF"

echo "[test_coredump] (4/4) Boot QEMU + run /bin/u_coredump via hamsh"
LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null' EXIT

# Prompt-aware drive: wait for hamsh's ready banner before sending input.
set +e
qemu_drive "$LOG" "$ELF" "[hamsh] M16.35 shell ready" 60 \
    -- "u_coredump" 10 \
       "exit" 1
rc="$QEMU_DRIVE_RC"
set -e

echo "[test_coredump] --- captured output ---"
cat "$LOG"
echo "[test_coredump] --- end output ---"

fail=0

check_marker() {
    local label="$1"
    local needle="$2"
    if grep -a -F -q "$needle" "$LOG"; then
        echo "[test_coredump] OK: $label  ('$needle')"
    else
        echo "[test_coredump] MISS: $label  ('$needle')"
        fail=1
    fi
}

check_marker "boot gate linked"    "[coredump] module linked; fatal-sig table OK"
check_marker "kernel wrote core"   "[coredump] pid="
check_marker "parent saw SIGSEGV"  "COREDUMP: parent saw SIGSEGV child"
check_marker "ET_CORE x86_64"      "COREDUMP: core ET_CORE x86_64 ok"
check_marker "PT_LOAD sentinel"    "COREDUMP: PT_LOAD sentinel match"
check_marker "NT_PRSTATUS rip"     "COREDUMP: NT_PRSTATUS rip ok"
check_marker "NT_PRPSINFO present" "COREDUMP: NT_PRPSINFO present"
check_marker "NT_AUXV present"     "COREDUMP: NT_AUXV present"
check_marker "fixture PASS"        "coredump: PASS"

# Diagnostics on failure.
if grep -a -F -q "coredump: FAIL" "$LOG"; then
    echo "[test_coredump] DIAG: fixture self-reported FAIL:"
    grep -a -F "coredump: FAIL" "$LOG" | head -5 || true
fi
if grep -a -F -q "trap-diag" "$LOG"; then
    echo "[test_coredump] DIAG: kernel reported a halting CPU exception"
    grep -a -F "trap-diag" "$LOG" | head -8 || true
fi

if [ "$fail" -ne 0 ]; then
    echo "[coredump] FAIL (qemu rc=$rc)"
    exit 1
fi

echo "[coredump] PASS -- kernel wrote a valid ELF ET_CORE on unhandled" \
     "SIGSEGV; PT_LOAD carries the sentinel and NT_PRSTATUS carries RIP"
