#!/usr/bin/env bash
# scripts/test_preempt.sh -- proves the Hamnix scheduler is preemptive.
#
# Before this milestone Hamnix multitasked purely cooperatively: a task
# yielded the CPU only inside a *blocking* syscall. A CPU-bound task
# that never made a blocking syscall starved every other task forever.
#
# The deliverable: a periodic timer interrupt can switch away from a
# running userland task to another STATE_READY task, so no task can
# monopolise the CPU.
#
# Test shape (two genuine ring-3 userland tasks):
#   - /bin/preempt_demo (the parent) is driven from hamsh. It SYS_SPAWNs
#     /bin/preempt_hog -- a sibling task that runs a tight infinite CPU
#     loop and NEVER issues a syscall again. The parent does NOT waitpid
#     the hog, so both are simultaneously runnable.
#   - The parent then runs its own long BOUNDED, syscall-free CPU loop
#     and, on completion, prints "[preempt] PASS".
#
# Under a cooperative-only scheduler the parent's bounded loop can never
# complete -- once the hog runs it owns the CPU forever -- so PASS is
# never printed and this test FAILs by timeout. Under the timer-driven
# preemptive scheduler the 100 Hz timer rotates the runqueue, the parent
# gets time slices, and "[preempt] PASS" is printed.
#
# QEMU is launched with -smp 1: Hamnix's runqueue is uniprocessor
# (single global current_idx). One CPU forces the parent and the hog to
# genuinely share that one CPU -- the only way the parent makes progress
# is real preemption of the never-yielding hog.
#
# Pass marker:  [test_preempt] PASS
# Fail marker:  [test_preempt] FAIL

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-vmlinux.elf
HAMSH_ELF=build/user/hamsh.elf
PREEMPT_TIMEOUT="${PREEMPT_TIMEOUT:-150}"

echo "[test_preempt] (1/3) Build userland (hamsh + preempt_demo + preempt_hog)"
bash scripts/build_user.sh

echo "[test_preempt] (2/3) Swap /init = hamsh; rebuild initramfs + kernel"
INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF"

echo "[test_preempt] (3/3) Boot QEMU (-smp 1) + drive preempt_demo via hamsh"
LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null' EXIT

set +e
(
    sleep 4
    printf 'preempt_demo\n'
    # Long settle: the parent's bounded CPU loop spans many quanta while
    # it shares the single CPU with the never-yielding hog. QEMU's TCG
    # interpreter runs the loop well below native speed, so this is
    # generous on purpose.
    sleep 135
    printf 'exit\n'
    sleep 1
) | timeout "${PREEMPT_TIMEOUT}s" qemu-system-x86_64 \
    -kernel "$ELF" \
    -smp 1 \
    -nographic \
    -no-reboot \
    -m 256M \
    -monitor none \
    -serial stdio \
    > "$LOG" 2>&1
rc=$?
set -e

echo "[test_preempt] --- captured output (last 120 lines) ---"
tail -n 120 "$LOG"
echo "[test_preempt] --- end output ---"

# rc 124 (timeout) is fine: the hog loops forever so a clean shutdown is
# not expected. Any other non-zero rc is a real QEMU failure.
if [ "$rc" -ne 0 ] && [ "$rc" -ne 124 ]; then
    echo "[test_preempt] FAIL: qemu exited rc=$rc" >&2
    echo "[test_preempt] FAIL"
    exit 1
fi

fail=0

if ! grep -F -q "[preempt] hog: running tight CPU loop" "$LOG"; then
    echo "[test_preempt] FAIL: hog never started -- spawn path broken" >&2
    fail=1
else
    echo "[test_preempt] OK   hog (syscall-free CPU loop sibling) started"
fi

if grep -F -q "[preempt] PASS" "$LOG"; then
    echo "[test_preempt] OK   parent completed its CPU loop alongside the non-yielding hog"
else
    echo "[test_preempt] FAIL: '[preempt] PASS' not seen -- the parent was" >&2
    echo "[test_preempt]       starved by the CPU hog; preemption did NOT happen." >&2
    fail=1
fi

if grep -F -q "[preempt] FAIL" "$LOG"; then
    echo "[test_preempt] FAIL: preempt_demo reported an internal failure" >&2
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_preempt] FAIL"
    exit 1
fi

echo "[test_preempt] PASS -- timer preempted a non-yielding userland CPU hog"
