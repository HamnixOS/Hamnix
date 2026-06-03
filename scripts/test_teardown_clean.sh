#!/usr/bin/env bash
# scripts/test_teardown_clean.sh — process-teardown #GP regression guard.
#
# A latent kernel bug made MANY self-tests end with a trailing General
# Protection fault (#GP) AFTER the workload had already printed its PASS
# marker. The fault fired during process / shell TEARDOWN: task_reap ->
# _free_task_user_pagetables walked a dying task's private page tables
# and, on hitting a MALFORMED page-table entry whose physical-address
# field was 0 (e.g. an identity-builder leaf such as 0x7 that maps
# physical page 0), descended into it as if it pointed at a real
# sub-table — reading "page tables" out of the real-mode IVT / BIOS at
# physical 0. Those garbage bytes were then mistaken for present entries
# and handed to free_pages at WILD non-canonical addresses, where the
# free-list store `*addr = head` raised a #GP (vec=0x0d) and the
# one-shot trap diagnostic HALTED the kernel.
#
# The fix (kernel/sched/core.ad::_free_task_user_pagetables): never
# descend into / free a page-table entry whose masked physical address
# is 0 — it is never a valid task-owned table or data page.
#
# This test boots a workload that SPAWNS and EXITS a user process
# (u_mmap: mmap + munmap + exit_group), forcing the page-free teardown
# path through task_reap, and asserts the serial log contains NO
# `[trap-diag] vec=0x000000000000000d` and NO `halting (one-shot diag`
# line. A clean teardown emits `[teardown] PASS`; the #GP halt (or any
# other halting trap-diag) emits `[teardown] FAIL`.

. "$(dirname "$0")/_build_lock.sh"
. "$(dirname "$0")/_qemu_drive.sh"
. "$(dirname "$0")/_ensure_ubin.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

# u_mmap is a small static Linux ELF that mmaps a page, munmaps it, and
# exit_group(0)s — a clean spawn+exit that drives task_reap's full
# page-table teardown. Reuse it as the teardown workload.
UBIN=tests/u-binary/u_mmap
ensure_ubin_or_skip test_teardown_clean u_mmap mmap

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf

echo "[test_teardown_clean] (1/4) Build userland (hamsh + helpers)"
bash scripts/build_user.sh
bash scripts/build_modules.sh

echo "[test_teardown_clean] (2/4) Swap /init = $HAMSH_ELF + embed u_mmap"
HAMNIX_EMBED_UBIN=1 INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py

echo "[test_teardown_clean] (3/4) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF"

echo "[test_teardown_clean] (4/4) Boot QEMU + spawn/exit u_mmap via hamsh"
LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null' EXIT

# Spawn u_mmap twice so both the first spawn AND a reuse-after-reap go
# through task_reap's teardown — exercising the page-free path more than
# once. Each "u_mmap" run exits and is reaped before the next prompt.
set +e
qemu_drive "$LOG" "$ELF" "[hamsh] M16.35 shell ready" 45 \
    -- "u_mmap" 3 \
       "u_mmap" 3 \
       "exit" 1
rc="$QEMU_DRIVE_RC"
set -e

echo "[test_teardown_clean] --- captured output ---"
cat "$LOG"
echo "[test_teardown_clean] --- end output ---"

fail=0

# Sanity: the workload actually ran (so the teardown path was reached).
if grep -a -F -q "U7: mmap ok" "$LOG"; then
    echo "[test_teardown_clean] OK: workload ran (mmap round-trip)"
else
    echo "[test_teardown_clean] MISS: workload did not run — teardown" \
         "path may not have been exercised"
    fail=1
fi

# Sanity: a child actually exited (reap fired).
if grep -a -E -q "task: pid [0-9]+ exited" "$LOG"; then
    echo "[test_teardown_clean] OK: a child task exited and was reaped"
else
    echo "[test_teardown_clean] MISS: no task-exit line — reap may not" \
         "have run"
    fail=1
fi

# The core assertion: NO #GP teardown halt.
if grep -a -F -q "[trap-diag] vec=0x000000000000000d" "$LOG"; then
    echo "[test_teardown_clean] FAIL-MARKER: #GP (vec=0x0d) trap-diag" \
         "fired during teardown"
    grep -a -F "trap-diag" "$LOG" | grep -a -v -F "install:" | head -8 || true
    fail=1
fi

# Broader assertion: NO one-shot halt of ANY kind.
if grep -a -F -q "halting (one-shot diag" "$LOG"; then
    echo "[test_teardown_clean] FAIL-MARKER: kernel halted on a" \
         "one-shot trap diagnostic"
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[teardown] FAIL"
    echo "[test_teardown_clean] FAIL (qemu rc=$rc)"
    exit 1
fi

echo "[teardown] PASS"
echo "[test_teardown_clean] PASS — process teardown frees pages cleanly;" \
     "no #GP / one-shot halt"
