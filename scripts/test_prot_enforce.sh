#!/usr/bin/env bash
# scripts/test_prot_enforce.sh -- W^X prot-write: mmap/mprotect PROT_*
# bits are AUTHORITATIVE at the PTE level.
#
# Stage 1a (test_u49_wxorx) marks user DATA pages No-Execute; Stage 1b
# (test_u50_wx_text_ro) marks loaded .text read-only. This fixture
# proves the COMPLEMENTARY userspace contract: mmap()/mprotect()'s
# PROT_WRITE bit is enforced by the page tables, not merely stored on the
# VMA. Concretely:
#
#   * mmap PROT_READ|PROT_WRITE -> a store SUCCEEDS.
#   * mprotect PROT_READ|PROT_EXEC -> the page is EXECUTABLE (a call into
#     it runs, no fault).
#   * mprotect PROT_READ -> a store now FAULTS: fs/elf.ad::vm_protect_range
#     clears PT_FLAG_RW on the live PTE, so the store raises a #PF that
#     arch/x86/kernel/trap_diag.ad::do_page_fault converts into SIGSEGV(11)
#     delivered to the faulting task's handler.
#
# Before this change PROT_WRITE was advisory at the page-table level: a
# read-only mapping stayed RW in the PTE and the store silently
# succeeded.
#
# This fixture drives the path end-to-end:
#   write() baseline -> mmap RW + write (ok) -> mmap + mprotect r-x +
#   CALL it (ok) -> arm SIGSEGV handler -> mprotect the rw page to
#   PROT_READ -> WRITE to it -> store faults -> kernel SIGSEGV -> handler
#   prints the trap marker + PASS and _exit(0)s.
#
# PASS criteria: all of these markers land on serial:
#   - "PROT: baseline ok"
#   - "PROT: rw write ok"
#   - "PROT: exec page ran ok"      (a PROT_READ|PROT_EXEC page runs)
#   - "PROT: handler armed"
#   - "PROT: RO trapped write"
#   - "[prot] PASS"
# And the boot log shows the kernel TRAPPED the write into the RO page:
#   - "[pf] W^X write-fault on RO user page"
#
# REQUIRES: musl-gcc on $PATH. Build step:
#     make -C tests/u-binary/src/prot_enforce install
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

UBIN=tests/u-binary/u_prot_enforce
ensure_ubin_or_skip test_prot_enforce u_prot_enforce prot_enforce

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf

echo "[test_prot_enforce] (1/4) Build userland (hamsh + helpers)"
bash scripts/build_user.sh
bash scripts/build_modules.sh

echo "[test_prot_enforce] (2/4) Swap /init = $HAMSH_ELF + embed u_prot_enforce"
HAMNIX_EMBED_UBIN=1 INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py

echo "[test_prot_enforce] (3/4) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF"

echo "[test_prot_enforce] (4/4) Boot QEMU + run /bin/u_prot_enforce via hamsh"
LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null' EXIT

# Prompt-aware drive: wait for hamsh's ready banner before sending input.
set +e
qemu_drive "$LOG" "$ELF" "[hamsh] M16.35 shell ready" 45 \
    -- "u_prot_enforce" 8 \
       "exit" 1
rc="$QEMU_DRIVE_RC"
set -e

echo "[test_prot_enforce] --- captured output ---"
cat "$LOG"
echo "[test_prot_enforce] --- end output ---"

fail=0

check_marker() {
    local label="$1"
    local needle="$2"
    if grep -a -F -q "$needle" "$LOG"; then
        echo "[test_prot_enforce] OK: $label  ('$needle')"
    else
        echo "[test_prot_enforce] MISS: $label  ('$needle')"
        fail=1
    fi
}

check_marker "kernel trapped write"   "[pf] W^X write-fault on RO user page"
check_marker "baseline ran"           "PROT: baseline ok"
check_marker "rw write ok"            "PROT: rw write ok"
check_marker "exec page ran"          "PROT: exec page ran ok"
check_marker "handler armed"          "PROT: handler armed"
check_marker "RO trapped write"       "PROT: RO trapped write"
check_marker "fixture PASS"           "[prot] PASS"

# Diagnostics: a HALTING trap-diag block (vec/err/rip) means the write
# fault was NOT routed to SIGSEGV and instead halted the kernel — the
# regression to watch. Benign install-time "[trap-diag] install:" lines
# are filtered out.
if grep -a -F "trap-diag" "$LOG" | grep -a -v -F "install:" | grep -a -q "vec="; then
    echo "[test_prot_enforce] DIAG: kernel reported a halting CPU exception"
    grep -a -F "trap-diag" "$LOG" | head -8 || true
fi
if grep -a -F -q "[prot] FAIL" "$LOG"; then
    echo "[test_prot_enforce] DIAG: fixture self-reported FAIL"
    grep -a -F "[prot] FAIL" "$LOG" | head -5 || true
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_prot_enforce] FAIL (qemu rc=$rc)"
    exit 1
fi

echo "[test_prot_enforce] PASS -- mmap/mprotect PROT_WRITE enforced;" \
     "write-to-PROT_READ traps to SIGSEGV; PROT_EXEC page runs"
