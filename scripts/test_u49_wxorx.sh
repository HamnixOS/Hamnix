#!/usr/bin/env bash
# scripts/test_u49_wxorx.sh -- W^X Stage 1a: NX on user DATA pages.
#
# W^X Stage 1a marks user DATA pages (stack / brk heap / anonymous mmap)
# No-Execute (PT_FLAG_NX, bit 63 in the leaf PTE), with EFER.NXE enabled
# on the BSP (syscall_init) and every AP (realmode trampoline). A jmp/
# call into such a page raises a #PF with the instruction-fetch (I/D)
# error bit, which arch/x86/kernel/trap_diag.ad::do_page_fault converts
# into SIGSEGV(11) delivered to the faulting task
# (kernel/sched/core.ad::deliver_fault_sigsegv). Code/.text pages are
# left executable in this stage (a later W^X slice marks them NX).
#
# This fixture drives the NX-on-stack path end-to-end:
#
#   write() baseline -> install a SIGSEGV handler -> copy a `ret` (0xC3)
#   machine-code byte onto a STACK buffer -> call into that buffer as a
#   function pointer -> the instruction fetch faults (stack is NX) ->
#   kernel delivers SIGSEGV -> the handler prints the trap marker + PASS
#   and _exit(0)s.
#
# PASS criteria: all of these markers land on serial:
#   - "WXORX: pre-exec write ok"
#   - "WXORX: handler armed"
#   - "WXORX: NX trapped exec-on-stack"
#   - "wxorx: PASS"
# And the boot log shows EFER NXE was enabled:
#   - "Hamnix: syscall_init: EFER after  NXE = "
#
# Build-on-missing: the fixture is gitignored (host-built). If absent,
# build it from tests/u-binary/src/wxorx; only SKIP on a real build
# failure (a genuine missing musl-gcc).
#
# REQUIRES: musl-gcc on $PATH. Build step:
#     make -C tests/u-binary/src/wxorx install
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

UBIN=tests/u-binary/u_wxorx
ensure_ubin_or_skip test_u49_wxorx u_wxorx wxorx

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf

echo "[test_u49_wxorx] (1/4) Build userland (hamsh + helpers)"
bash scripts/build_user.sh
bash scripts/build_modules.sh

echo "[test_u49_wxorx] (2/4) Swap /init = $HAMSH_ELF + embed u_wxorx"
HAMNIX_EMBED_UBIN=1 INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py

echo "[test_u49_wxorx] (3/4) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF"

echo "[test_u49_wxorx] (4/4) Boot QEMU + run /bin/u_wxorx via hamsh"
LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null' EXIT

# Prompt-aware drive: wait for hamsh's ready banner before sending input
# (a fixed sleep races boot-time variance -- see _qemu_drive.sh).
set +e
qemu_drive "$LOG" "$ELF" "[hamsh] M16.35 shell ready" 45 \
    -- "u_wxorx" 8 \
       "exit" 1
rc="$QEMU_DRIVE_RC"
set -e

echo "[test_u49_wxorx] --- captured output ---"
cat "$LOG"
echo "[test_u49_wxorx] --- end output ---"

fail=0

check_marker() {
    local label="$1"
    local needle="$2"
    # -a: the serial log carries binary bytes; treat it as text.
    if grep -a -F -q "$needle" "$LOG"; then
        echo "[test_u49_wxorx] OK: $label  ('$needle')"
    else
        echo "[test_u49_wxorx] MISS: $label  ('$needle')"
        fail=1
    fi
}

check_marker "EFER NXE enabled"   "Hamnix: syscall_init: EFER after  NXE = "
check_marker "pre-exec write"     "WXORX: pre-exec write ok"
check_marker "handler armed"      "WXORX: handler armed"
check_marker "NX trapped exec"    "WXORX: NX trapped exec-on-stack"
check_marker "fixture PASS"       "wxorx: PASS"

# Diagnostics: surface the next-gap signal for triage.
if grep -a -F -q "[pf] NX exec-fault" "$LOG"; then
    echo "[test_u49_wxorx] DIAG: kernel NX fault trace:"
    grep -a -F "[pf] NX exec-fault" "$LOG" | head -5 || true
fi
if grep -a -F -q "trap-diag" "$LOG"; then
    echo "[test_u49_wxorx] DIAG: kernel reported a halting CPU exception"
    grep -a -F "trap-diag" "$LOG" | head -8 || true
fi
if grep -a -F -q "wxorx: FAIL" "$LOG"; then
    echo "[test_u49_wxorx] DIAG: fixture self-reported FAIL"
    grep -a -F "wxorx: FAIL" "$LOG" | head -5 || true
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_u49_wxorx] FAIL (qemu rc=$rc)"
    exit 1
fi

echo "[test_u49_wxorx] PASS -- W^X Stage 1a: NX on user data pages;" \
     "exec-on-stack traps to SIGSEGV"
