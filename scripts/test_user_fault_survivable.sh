#!/usr/bin/env bash
# scripts/test_user_fault_survivable.sh
#
# Regression guard: a USERSPACE process fault must NEVER halt the whole
# kernel — it must deliver SIGSEGV to (and reap) the faulting process,
# and the system must keep running.
#
# THE BUG (user-reported): `ls | grep echo` inside `enter linux {sh}`
# took a CPL3 #PF, err=0x05 (P=1/U=1/W=0) — a USER-mode READ protection
# violation reading a kernel-space address (cr2=0xfffffffffffffff8, a
# corrupt user pointer). do_page_fault's read-fault branch returned 0
# unconditionally, so the fault fell into arch/x86/kernel/trap_diag.ad's
# print-and-HALT path and took the OS down ("[trap-diag] halting").
#
# THE FIX: do_page_fault now routes a user-mode (U=1) read protection
# fault that the MM path cannot resolve to deliver_fault_sigsegv
# (SIGSEGV + coredump + task reap), exactly like the write/NX paths.
# The trap-diag halt is reserved for genuine KERNEL (CPL0) faults.
#
# FIXTURE (tests/u-binary/src/badread_segv/badread_segv.c):
#   - A forked child reads (void*)-8, a kernel-half pointer, from CPL3
#     -> the exact err=0x05 fault -> SIGSEGV (no handler) -> coredump +
#     reap.
#   - The PARENT waitpid()s (asserts WIFSIGNALED && WTERMSIG==SIGSEGV)
#     and prints "parent still alive after child segfault" — which it
#     could ONLY do if the kernel did NOT halt on the child's fault.
#
# PASS criteria:
#   - the fixture's own PASS markers reach serial, AND
#   - the kernel did NOT emit "[trap-diag] halting" (the halt path).
#
# REQUIRES: musl-gcc on $PATH (build-on-missing via _ensure_ubin.sh).
#
# A trailing QEMU rc=124 AFTER the markers is benign (we `exit` hamsh but
# the watchdog reaps qemu); the grep marker checks are authoritative.

. "$(dirname "$0")/_build_lock.sh"
. "$(dirname "$0")/_qemu_drive.sh"
. "$(dirname "$0")/_ensure_ubin.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

UBIN=tests/u-binary/u_badread_segv
ensure_ubin_or_skip test_user_fault_survivable u_badread_segv badread_segv

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf

echo "[test_user_fault_survivable] (1/4) Build userland (hamsh + helpers)"
bash scripts/build_user.sh
bash scripts/build_modules.sh

echo "[test_user_fault_survivable] (2/4) Swap /init = $HAMSH_ELF + embed u_badread_segv"
HAMNIX_EMBED_UBIN=1 INIT_ELF="$HAMSH_ELF" \
    python3 scripts/build_initramfs.py

echo "[test_user_fault_survivable] (3/4) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF"

echo "[test_user_fault_survivable] (4/4) Boot QEMU + run /bin/u_badread_segv via hamsh"
LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null' EXIT

# Prompt-aware drive: wait for hamsh's ready banner, run the fixture, and
# crucially run a SECOND command (echo) AFTER it — that command only
# echoes if the shell is still being scheduled, i.e. the kernel survived
# the child's segfault. Boot under KVM where available.
KVM_ARGS=()
if [ -w /dev/kvm ]; then
    KVM_ARGS=(-enable-kvm -cpu host)
fi

set +e
QEMU_EXTRA_ARGS="${KVM_ARGS[*]:-}" \
qemu_drive "$LOG" "$ELF" "[hamsh] M16.35 shell ready" 60 \
    -- "u_badread_segv" 10 \
       "echo KERNEL_STILL_ALIVE_$$" 3 \
       "exit" 1
rc="$QEMU_DRIVE_RC"
set -e

echo "[test_user_fault_survivable] --- captured output ---"
cat "$LOG"
echo "[test_user_fault_survivable] --- end output ---"

fail=0

check_marker() {
    local label="$1"
    local needle="$2"
    if grep -a -F -q "$needle" "$LOG"; then
        echo "[test_user_fault_survivable] OK: $label  ('$needle')"
    else
        echo "[test_user_fault_survivable] MISS: $label  ('$needle')"
        fail=1
    fi
}

# (1) The kernel must NOT have taken the diagnostic halt.
if grep -a -F -q "[trap-diag] halting" "$LOG"; then
    echo "[test_user_fault_survivable] FAIL: kernel hit the trap-diag HALT" \
         "on a USER fault — the box went down instead of delivering SIGSEGV."
    grep -a -F "trap-diag" "$LOG" | head -12 || true
    exit 1
fi

# (2) The fixture's child died by SIGSEGV and the parent SURVIVED.
check_marker "child SIGSEGV reaped"     "BADREAD: parent saw SIGSEGV child"
check_marker "parent survived fault"    "BADREAD: parent still alive after child segfault"
check_marker "fixture PASS"             "badread: PASS"

# (3) The shell kept being scheduled AFTER the segfault (post-fault cmd).
check_marker "shell alive post-fault"   "KERNEL_STILL_ALIVE_$$"

# (4) The kernel's SIGSEGV-route diagnostic fired (positive confirmation
#     the read-prot fault took the new path, not the old halt). One of the
#     read-prot / unmapped SIGSEGV lines is enough.
if grep -a -E -q "\[pf\] (user read-prot fault|user fault on unmapped) va=" "$LOG"; then
    echo "[test_user_fault_survivable] OK: kernel routed the user fault to SIGSEGV"
else
    echo "[test_user_fault_survivable] NOTE: no [pf] SIGSEGV-route line seen" \
         "(fixture PASS + no halt is still authoritative)"
fi

if [ "$fail" -ne 0 ]; then
    echo "[user_fault_survivable] FAIL (qemu rc=$rc)"
    exit 1
fi

echo "[user_fault_survivable] PASS -- a deliberate user segfault delivered" \
     "SIGSEGV (+coredump+reap) and the kernel kept running (qemu rc=$rc)"
