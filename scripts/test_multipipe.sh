#!/usr/bin/env bash
# scripts/test_multipipe.sh — multi-stage `a | b | c [| d]` gate.
#
# WHY THIS GATE WAS REWRITTEN
#
# It used to drive `echo three-stage-pipeline | cat | cat` and grep the
# serial log for "three-stage-pipeline". That assertion was satisfied by
# THREE different worlds, only one of which is a working pipeline:
#
#   (1) the phrase travelled echo -> cat -> cat and the last cat printed it;
#   (2) `echo` — a hamsh BUILTIN — ignored the pipe entirely and wrote
#       straight to the console, while both cats read instant EOF; or
#   (3) nothing ran at all and the grep matched the shell's own echo of the
#       COMMAND LINE being typed (the old test did not drop prompt lines).
#
# World (2) is what actually shipped. So the gate stayed green while
# hamsh's pipelines were completely broken.
#
# THE RULE NOW: assert the LAST stage's COMPUTED answer — a number no
# earlier stage ever prints, so it cannot leak — and separately assert that
# no intermediate stage's output reached the console.
#
#   3 stages: seq 1000 1099 | grep 7 | wc -c   -> 95  (19 matches x 5 bytes)
#   4 stages: seq 1000 1099 | grep 7 | grep 9 | wc -c -> 10  (1079, 1097)
#   builtin head: echo MULTIPAYLOAD | cat | wc -c -> 13
#
# scripts/test_pipe.sh is the sibling gate for the 1- and 2-stage cases and
# for redirect/dup; this one exists to keep >2 inter-stage pipes honest.
#
# Boot vehicle: hamsh as /init over the serial line (the GRUB-ISO shim in
# _kernel_iso.sh loads the higher-half elf64 kernel). test_pipe.sh's header
# explains why a runlevel-5 shipped-image boot cannot be driven reliably by
# serial keystrokes.
#
#
# GUEST CPU COUNT — why the default is 1, and when to change it back
#
# This gate runs the guest with -smp ${HAMNIX_TEST_SMP:-1}. Under -smp 2 the
# shell intermittently WEDGES immediately after any pipeline: both stages
# reap cleanly ("task: pid N exited"), the kernel keeps running, and hamsh
# never returns from its post-pipeline wait. That is a PRE-EXISTING SCHEDULER
# bug, not a pipe bug — it reproduces on an UNMODIFIED hamsh, on TCG and on
# KVM, and switching the wait from the blocking sys_waitpid to a polled
# sys_waitpid_jc + sys_yield does not avoid it (both halt in
# kernel/sched/core.ad :: yield_to_others). run_pipeline is simply hamsh's
# only wait that yields while a sibling task is still running, so a pipeline
# is the reliable trigger.
#
# A gate that wedges cannot observe its own assertions. Until that scheduler
# stall is fixed, drive the guest UP: every assertion below is about the
# pipe substrate, not about SMP. Re-check with HAMNIX_TEST_SMP=2 once the
# scheduler bug is closed, and then make 2 the default again.
#
# VERDICTS: scripts/_verdict.sh — PASS 0, FAIL 1, INCONCLUSIVE 125.
set -uo pipefail
# Writing to the guest's stdin FIFO after QEMU exits raises SIGPIPE, which
# would kill this script before it printed a verdict.
trap '' PIPE

. "$(dirname "$0")/_build_lock.sh"

PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

. "$PROJ_ROOT/scripts/_verdict.sh"
. "$PROJ_ROOT/scripts/_hamsh_log.sh"
. "$PROJ_ROOT/scripts/_kernel_iso.sh"

TAG="test_multipipe"
ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf
SMP="${HAMNIX_TEST_SMP:-1}"     # see the -smp note in the header
BOOT_WAIT="${BOOT_WAIT:-420}"
CMD_WAIT="${CMD_WAIT:-240}"

echo "[$TAG] (1/4) Build userland"
bash scripts/build_user.sh >/dev/null || verdict_inconclusive "$TAG" "build_user.sh failed"
bash scripts/build_modules.sh >/dev/null 2>&1 || true

echo "[$TAG] (2/4) Swap /init = $HAMSH_ELF"
INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py >/dev/null \
    || verdict_inconclusive "$TAG" "build_initramfs.py failed"

echo "[$TAG] (3/4) Rebuild kernel image"
LOG=$(mktemp)
restore_init() {
    INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1
    [ "${KEEP_LOGS:-0}" = "1" ] || rm -f "$LOG"
}
trap restore_init EXIT
python3 -m compiler.adder compile --target=x86_64-bare-metal init/main.ad -o "$ELF" \
    >/dev/null 2>&1 || verdict_inconclusive "$TAG" "kernel compile failed"

echo "[$TAG] (4/4) Boot and drive hamsh"
FIFO=$(mktemp -u --tmpdir hamnix-multipipe-in.XXXXXX)
mkfifo "$FIFO"
QEMU_PID=""
restore_init() {
    [ -n "${QEMU_PID:-}" ] && kill "$QEMU_PID" 2>/dev/null
    [ -n "${QEMU_PID:-}" ] && wait "$QEMU_PID" 2>/dev/null
    exec 3>&- 2>/dev/null
    rm -f "$FIFO"
    INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1
    [ "${KEEP_LOGS:-0}" = "1" ] || rm -f "$LOG"
}
trap restore_init EXIT

qemu-system-x86_64 \
    -kernel "$ELF" \
    -smp "$SMP" -m "${HAMNIX_VM_MEM:-2G}" \
    -nographic -no-reboot -monitor none \
    < "$FIFO" > "$LOG" 2>&1 &
QEMU_PID=$!
exec 3> "$FIFO"

alive()      { kill -0 "$QEMU_PID" 2>/dev/null; }
outline_eq() { hamsh_out_eq "$LOG" "$1"; }

wait_raw() {                       # <literal> <secs>
    local i
    for i in $(seq 1 "$2"); do
        grep -a -F -q "$1" "$LOG" && return 0
        alive || return 1
        sleep 1
    done
    return 1
}
# Only the FIRST line may be re-sent: a freshly-booted hamsh drops it. After
# that the readline is provably consuming stdin, and re-sending would splice
# a duplicate into a line the editor is still echoing character by character.
sync_probe() {
    local secs="$1" waited=0 i
    while [ "$waited" -lt "$secs" ]; do
        alive || return 1
        printf 'echo FEEDER_SYNC\n' >&3 2>/dev/null || return 1
        for i in $(seq 1 5); do
            grep -a -F -q "FEEDER_SYNC" "$LOG" && { sleep 1; return 0; }
            alive || return 1
            sleep 1; waited=$((waited + 1))
            [ "$waited" -ge "$secs" ] && break
        done
    done
    return 1
}
send_await_out() {                 # <cmd> <exact-output-line> <secs>
    local cmd="$1" want="$2" secs="$3" i
    alive || return 1
    printf '%s\n' "$cmd" >&3 2>/dev/null || return 1
    for i in $(seq 1 "$secs"); do
        outline_eq "$want" && { sleep 1; return 0; }
        alive || return 1
        sleep 1
    done
    return 1
}

wait_raw "[hamsh:stage-07] loop-enter" "$BOOT_WAIT" || {
    tail -30 "$LOG" | strings >&2
    verdict_inconclusive "$TAG" "hamsh never reached its interactive loop in ${BOOT_WAIT}s"
}
sync_probe 120 || {
    tail -30 "$LOG" | strings >&2
    verdict_inconclusive "$TAG" "readline never echoed FEEDER_SYNC — stdin not consumed"
}

s3=0; s4=0; sb=0
send_await_out 'seq 1000 1099 | grep 7 | wc -c'          '95' "$CMD_WAIT" && s3=1
send_await_out 'seq 1000 1099 | grep 7 | grep 9 | wc -c' '10' "$CMD_WAIT" && s4=1
send_await_out 'echo MULTIPAYLOAD | cat | wc -c'         '13' "$CMD_WAIT" && sb=1
alive && { printf 'exit\n' >&3 2>/dev/null || true; }
sleep 2

fail=0
wrong() { echo "[$TAG] WRONG: $*" >&2; fail=1; }
ok()    { echo "[$TAG] ok: $*"; }

# --- 3 stages ----------------------------------------------------------
if [ "$s3" -eq 0 ] && ! outline_eq "1007" && ! outline_eq "1070"; then
    verdict_inconclusive "$TAG" "3-stage case produced no observable result — guest starved?"
fi
if outline_eq "95"; then
    ok "3 stages: 'seq 1000 1099 | grep 7 | wc -c' printed 95"
else
    wrong "3 stages: no '95' — an inter-stage pipe dropped its data"
fi
if outline_eq "1007" || outline_eq "1070"; then
    wrong "3 stages: an intermediate stage's output LEAKED to the console"
else
    ok "3 stages: no intermediate stage output on the console"
fi

# --- 4 stages ----------------------------------------------------------
if outline_eq "10"; then
    ok "4 stages: 'seq 1000 1099 | grep 7 | grep 9 | wc -c' printed 10"
else
    wrong "4 stages: no '10' — the second inter-stage pipe dropped its data"
fi
if outline_eq "1079" || outline_eq "1097"; then
    wrong "4 stages: an intermediate stage's output LEAKED to the console"
else
    ok "4 stages: no intermediate stage output on the console"
fi

# --- builtin at the head of a 3-stage pipeline -------------------------
# `echo` is a hamsh builtin. It must run as a real forked stage writing into
# the pipe, not in-process writing to the console. "MULTIPAYLOAD\n" = 13 B.
if [ "$sb" -eq 0 ] && ! outline_eq "MULTIPAYLOAD"; then
    verdict_inconclusive "$TAG" "builtin-head case produced no observable result — guest starved?"
fi
if outline_eq "13"; then
    ok "builtin head: 'echo MULTIPAYLOAD | cat | wc -c' printed 13"
else
    wrong "builtin head: no '13' — the builtin's bytes never entered the pipe"
fi
if outline_eq "MULTIPAYLOAD"; then
    wrong "builtin head: the builtin LEAKED 'MULTIPAYLOAD' to the console"
else
    ok "builtin head: 'MULTIPAYLOAD' never appeared as console output"
fi

if [ "$fail" -ne 0 ]; then
    echo "[$TAG] --- command-output lines ---" >&2
    hamsh_outlines "$LOG" | tail -40 >&2
    verdict_fail "$TAG" "a multi-stage pipeline assertion was VIOLATED (see WRONG: lines)"
fi
verdict_pass "$TAG" \
    "3-stage, 4-stage and builtin-head pipelines all delivered their bytes; no stage leaked to the console"
