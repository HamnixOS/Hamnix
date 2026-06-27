#!/usr/bin/env bash
# scripts/test_lazyplt_fork.sh
#
# STATUS T24 tight repro: glibc LAZY PLT resolution (_dl_runtime_resolve /
# _dl_fixup) after a fork. This is the apt acquire-method `jmp *r11` #GP
# minus the network — a DYNAMIC glibc binary whose forked child + post-
# reap parent each call a never-before-resolved libc function, forcing
# _dl_runtime_resolve in each address space's GOT.
#
# OUTCOMES:
#   "lazyplt: PASS"            -> lazy resolution works after fork; the T24
#                                corruption does NOT reproduce in this
#                                (network-free) shape.
#   "lazyplt: FAIL child ..."  -> the child took the #GP — T24 reproduced.
#                                The kernel SURVIVES either way (the
#                                user-#GP-survivability fix), and the [gp]
#                                diag line + coredump pin the faulting RIP
#                                / instruction bytes for root-causing.
#
# Authoritative signal: the fixture's PASS/FAIL marker, AND that the
# kernel did NOT take the trap-diag halt (a userspace fault must never
# halt the box). A FAIL here is still a CLEAN run — it means the repro
# fired and the diagnostics are in the log.

. "$(dirname "$0")/_build_lock.sh"
. "$(dirname "$0")/_qemu_drive.sh"
. "$(dirname "$0")/_ensure_ubin.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

UBIN=tests/u-binary/u_lazyplt_fork
ensure_ubin_or_skip test_lazyplt_fork u_lazyplt_fork lazyplt_fork

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf

echo "[test_lazyplt_fork] (1/4) Build userland (hamsh + helpers)"
bash scripts/build_user.sh
bash scripts/build_modules.sh

echo "[test_lazyplt_fork] (2/4) Swap /init = $HAMSH_ELF + embed u_lazyplt_fork"
HAMNIX_EMBED_UBIN=1 INIT_ELF="$HAMSH_ELF" \
    python3 scripts/build_initramfs.py

echo "[test_lazyplt_fork] (3/4) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF"

echo "[test_lazyplt_fork] (4/4) Boot QEMU + run /bin/u_lazyplt_fork via hamsh"
LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null' EXIT

KVM_ARGS=()
if [ -w /dev/kvm ]; then
    KVM_ARGS=(-enable-kvm -cpu host)
fi

set +e
QEMU_EXTRA_ARGS="${KVM_ARGS[*]:-}" \
qemu_drive "$LOG" "$ELF" "[hamsh] M16.35 shell ready" 60 \
    -- "u_lazyplt_fork" 12 \
       "echo KERNEL_STILL_ALIVE_$$" 3 \
       "exit" 1
rc="$QEMU_DRIVE_RC"
set -e

echo "[test_lazyplt_fork] --- captured output ---"
cat "$LOG"
echo "[test_lazyplt_fork] --- end output ---"

# A userspace fault must NEVER halt the box.
if grep -a -F -q "[trap-diag] halting" "$LOG"; then
    echo "[test_lazyplt_fork] FAIL: kernel hit the trap-diag HALT on a" \
         "userspace fault — the box went down."
    grep -a -F "trap-diag" "$LOG" | head -12 || true
    exit 1
fi

if ! grep -a -F -q "KERNEL_STILL_ALIVE_$$" "$LOG"; then
    echo "[test_lazyplt_fork] FAIL: shell did not survive to run the" \
         "post-fixture command (kernel may have wedged)."
    exit 1
fi

if grep -a -F -q "lazyplt: PASS" "$LOG"; then
    echo "[test_lazyplt_fork] PASS: lazy PLT resolution after fork works;" \
         "T24 #GP did NOT reproduce in the network-free shape (rc=$rc)."
    exit 0
fi

if grep -a -F -q "lazyplt: FAIL child" "$LOG"; then
    echo "[test_lazyplt_fork] REPRO: child took the lazy-PLT #GP (T24" \
         "reproduced). Kernel survived; see [gp] diag + coredump above."
    grep -a -E "\[gp\] " "$LOG" | head || true
    # A clean repro is the desired diagnostic outcome, not a test failure.
    exit 0
fi

echo "[test_lazyplt_fork] INCONCLUSIVE: no lazyplt PASS/FAIL marker seen" \
     "(fixture may have skipped or the build embedded the wrong init)."
exit 1
