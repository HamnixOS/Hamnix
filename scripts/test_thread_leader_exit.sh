#!/usr/bin/env bash
# scripts/test_thread_leader_exit.sh -- thread-group leader-exit reap
# regression gate (the latent #DF at load_cr3+0x3, kernel TODO "Latent
# crashes").
#
# Story: CLONE_VM | CLONE_THREAD threads share the creator's PML4
# (set_task_cr3), and exit_group does NOT terminate the group's other
# threads. When the LEADER exits and hamsh's waitpid reaps it,
# task_reap used to tear the SHARED address space down while the worker
# thread was still running: vma_clear freed the worker's mmap'd stack,
# the brk arm freed the live heap, and free_page(cr3) returned the
# worker's LIVE PML4 to the buddy allocator. Once re-issued and
# scribbled, the worker's next dispatch did load_cr3(<garbage>) and the
# instruction fetch of load_cr3's own `ret` double-faulted -- AFTER the
# suite's PASS markers, so green tests hid it.
#
# The fixture (tests/u-binary/src/thread_leader_exit) starts a worker
# that prints 6 heartbeats on a 300 ms nanosleep cadence, then the main
# thread returns immediately. hamsh reaps the leader within
# milliseconds, so heartbeats >= 2 print AFTER the leader was reaped.
#
# PASS criteria (all on serial):
#   - "TLX: main exiting"        (leader reached exit_group)
#   - "TLX: worker alive 5"      (worker survived the leader's reap)
#   - "TLX: worker done"         (worker ran its full loop)
#   - "TLX-SHELL-OK"             (hamsh still healthy afterwards)
# plus a negative: no "TRAP: vector 8" (#DF) anywhere in the log.

. "$(dirname "$0")/_build_lock.sh"
. "$(dirname "$0")/_qemu_drive.sh"
. "$(dirname "$0")/_ensure_ubin.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

UBIN=tests/u-binary/u_thread_leader_exit
ensure_ubin_or_skip test_thread_leader_exit u_thread_leader_exit thread_leader_exit

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf

echo "[test_thread_leader_exit] (1/4) Build userland (hamsh + helpers)"
bash scripts/build_user.sh
bash scripts/build_modules.sh

echo "[test_thread_leader_exit] (2/4) Swap /init = $HAMSH_ELF + embed u_thread_leader_exit"
HAMNIX_EMBED_UBIN=1 INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py

echo "[test_thread_leader_exit] (3/4) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF"

echo "[test_thread_leader_exit] (4/4) Boot QEMU + run /bin/u_thread_leader_exit via hamsh"
LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null' EXIT

# Prompt-aware drive. The fixture's leader returns instantly, so hamsh
# reaps it and gives the prompt back while the worker is still printing
# heartbeats; the 8 s dwell after the spawn captures all 6 of them. The
# follow-up echo proves the shell (and the allocator behind it) is
# still healthy after the leader's reap.
set +e
qemu_drive "$LOG" "$ELF" "[hamsh] M16.35 shell ready" 55 \
    -- "u_thread_leader_exit" 8 \
       "echo TLX-SHELL-OK" 3 \
       "exit" 1
rc="$QEMU_DRIVE_RC"
set -e

echo "[test_thread_leader_exit] --- captured output ---"
cat "$LOG"
echo "[test_thread_leader_exit] --- end output ---"

fail=0

check_marker() {
    local label="$1"
    local needle="$2"
    if grep -F -q "$needle" "$LOG"; then
        echo "[test_thread_leader_exit] OK: $label  ('$needle')"
    else
        echo "[test_thread_leader_exit] MISS: $label  ('$needle')"
        fail=1
    fi
}

check_marker "leader exited"             "TLX: main exiting"
check_marker "worker survived the reap"  "TLX: worker alive 5"
check_marker "worker completed"          "TLX: worker done"
check_marker "shell healthy afterwards"  "TLX-SHELL-OK"

# Negative: a #DF anywhere is an automatic fail -- this is the exact
# signature the shared-mm reap guard exists to prevent. trap_diag logs
# exceptions as "[trap-diag] vec=<hex>"; vector 8 is the double fault.
if grep -E -q '\[trap-diag\] vec=0x0*8[^0-9a-f]|TRAP: vector 8' "$LOG"; then
    echo "[test_thread_leader_exit] FAIL: kernel reported a #DF (vector 8)"
    grep -E "trap-diag|TRAP: vector" "$LOG" | head -5 || true
    fail=1
fi

# Diagnostics: surface next-gap signals for triage. Match only REAL
# exception reports ("[trap-diag] vec=..."), not the boot-time
# "[trap-diag] install:" IDT lines.
if grep -E -q '\[trap-diag\] vec=|TRAP: vector' "$LOG"; then
    echo "[test_thread_leader_exit] DIAG: kernel reported a CPU exception"
    grep -E '\[trap-diag\] vec=|TRAP: vector' "$LOG" | head -5 || true
fi
if grep -F -q "cr3-sync" "$LOG"; then
    echo "[test_thread_leader_exit] DIAG: [cr3-sync] kernel-half divergence warning"
    grep -F "cr3-sync" "$LOG" | head -5 || true
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_thread_leader_exit] FAIL (qemu rc=$rc)"
    exit 1
fi

echo "[test_thread_leader_exit] PASS -- shared address space survives leader reap; no #DF"
