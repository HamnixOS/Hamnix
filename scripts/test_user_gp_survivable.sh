#!/usr/bin/env bash
# scripts/test_user_gp_survivable.sh
#
# Regression guard (sibling of test_user_fault_survivable.sh, which
# covers the #PF case): a USERSPACE #GP must NEVER halt the whole kernel
# — it must deliver SIGSEGV to (and reap) the faulting process, and the
# system must keep running.
#
# THE BUG: a Linux-namespace user process that took a #GP (vec=0x0d,
# err=0x0) — e.g. the forked apt acquire-method chain executing a
# `jmp *r11` (41 ff e3) with a NON-CANONICAL r11 resolved through a
# corrupt GOT slot (STATUS T24) — was not delivered SIGSEGV.
# trap_diag_stub_0d fell straight into common_trap_diag's print-and-HALT
# (and its diag dump SMAP-faulted reading the user RIP), taking the box
# down instead of just killing the offending process.
#
# THE FIX: trap_diag_stub_0d now calls do_gp_fault(), which routes a
# CPL=3 #GP to deliver_fault_sigsegv (SIGSEGV + coredump + reap); the
# diag RIP-byte dump is SMAP-bracketed. A CPL=0 kernel #GP still halts.
# trap_gp_install() wires the productive stub UNCONDITIONALLY (every
# boot, not just the dev-gated trap_diag_install path), mirroring
# trap_pf_install for vector 14.
#
# FIXTURE (tests/u-binary/src/badjmp_gp/badjmp_gp.c):
#   - A forked child `jmp`s to a non-canonical address (the exact
#     `jmp *r11` instruction bytes) -> #GP -> SIGSEGV (no handler) ->
#     coredump + reap.
#   - The PARENT waitpid()s (asserts WIFSIGNALED && WTERMSIG==SIGSEGV)
#     and prints "parent still alive after child #GP" — which it could
#     ONLY do if the kernel did NOT halt on the child's #GP.
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

UBIN=tests/u-binary/u_badjmp_gp
ensure_ubin_or_skip test_user_gp_survivable u_badjmp_gp badjmp_gp

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf

echo "[test_user_gp_survivable] (1/4) Build userland (hamsh + helpers)"
bash scripts/build_user.sh
bash scripts/build_modules.sh

echo "[test_user_gp_survivable] (2/4) Swap /init = $HAMSH_ELF + embed u_badjmp_gp"
HAMNIX_EMBED_UBIN=1 INIT_ELF="$HAMSH_ELF" \
    python3 scripts/build_initramfs.py

echo "[test_user_gp_survivable] (3/4) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF"

echo "[test_user_gp_survivable] (4/4) Boot QEMU + run /bin/u_badjmp_gp via hamsh"
LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null' EXIT

KVM_ARGS=()
if [ -w /dev/kvm ]; then
    KVM_ARGS=(-enable-kvm -cpu host)
fi

set +e
QEMU_EXTRA_ARGS="${KVM_ARGS[*]:-}" \
qemu_drive "$LOG" "$ELF" "[hamsh] M16.35 shell ready" 60 \
    -- "u_badjmp_gp" 10 \
       "echo KERNEL_STILL_ALIVE_$$" 3 \
       "exit" 1
rc="$QEMU_DRIVE_RC"
set -e

echo "[test_user_gp_survivable] --- captured output ---"
cat "$LOG"
echo "[test_user_gp_survivable] --- end output ---"

fail=0

check_marker() {
    local label="$1"
    local needle="$2"
    if grep -a -F -q "$needle" "$LOG"; then
        echo "[test_user_gp_survivable] OK: $label  ('$needle')"
    else
        echo "[test_user_gp_survivable] MISS: $label  ('$needle')"
        fail=1
    fi
}

# (1) The kernel must NOT have taken the diagnostic halt.
if grep -a -F -q "[trap-diag] halting" "$LOG"; then
    echo "[test_user_gp_survivable] FAIL: kernel hit the trap-diag HALT" \
         "on a USER #GP — the box went down instead of delivering SIGSEGV."
    grep -a -F "trap-diag" "$LOG" | head -12 || true
    exit 1
fi

# (2) The fixture's child died by SIGSEGV and the parent SURVIVED.
check_marker "child SIGSEGV reaped"     "BADJMP: parent saw SIGSEGV child"
check_marker "parent survived #GP"      "BADJMP: parent still alive after child #GP"
check_marker "fixture PASS"             "badjmp: PASS"

# (3) The shell kept being scheduled AFTER the #GP (post-fault cmd).
check_marker "shell alive post-fault"   "KERNEL_STILL_ALIVE_$$"

# (4) Positive confirmation the #GP took the new SIGSEGV route.
if grep -a -E -q "\[gp\] user #GP rip=" "$LOG"; then
    echo "[test_user_gp_survivable] OK: kernel routed the user #GP to SIGSEGV"
else
    echo "[test_user_gp_survivable] NOTE: no [gp] SIGSEGV-route line seen" \
         "(fixture PASS + no halt is still authoritative)"
fi

if [ "$fail" -ne 0 ]; then
    echo "[user_gp_survivable] FAIL (qemu rc=$rc)"
    exit 1
fi

echo "[user_gp_survivable] PASS -- a deliberate user #GP delivered" \
     "SIGSEGV (+coredump+reap) and the kernel kept running (qemu rc=$rc)"
