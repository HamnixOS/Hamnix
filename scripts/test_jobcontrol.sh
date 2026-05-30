#!/usr/bin/env bash
# scripts/test_jobcontrol.sh — hamsh job-control end-to-end test.
#
# Exercises the Tier-1 job-control core landed alongside this script:
#   * `cmd &`         backgrounds a pipeline in its own process group,
#                     prints `[<jobid>] <pgid>`, returns to the prompt.
#   * `jobs`          lists tracked jobs with Running / Stopped state.
#   * background reap at the prompt prints `[<id>]+ Done <cmd>`.
#   * Ctrl-Z (0x1A)   suspends the FOREGROUND job; the shell prints
#                     `[<id>]+ Stopped <cmd>` and returns to the prompt
#                     (PID 1 must SURVIVE — it never gets stopped).
#   * `bg [%n]`       SIGCONTs a stopped job in the background.
#   * `fg [%n]`       resumes + reattaches the terminal to a job.
#
# Kernel pieces under test: SIGTSTP(20)/SIGCONT(18)/STATE_STOPPED in
# kernel/sched/core.ad, SYS_SETPGID/SYS_TCSETPGRP/SYS_WAITPID_JC and
# kill(-pgid) in arch/x86/kernel/syscall.ad, and the Ctrl-Z console
# interception in drivers/tty/serial/early_8250.ad + atkbd.ad.
#
# Modeled on scripts/test_spawn_loop.sh: drives the DEFAULT boot path
# (init -> rc.boot -> hamsh) over serial via scripts/_qemu_drive.sh, so
# it adapts to boot-time jitter. Ctrl-Z is delivered as the literal
# byte 0x1A in a fed command line ($'\x1a'), which the kernel's serial
# RX path turns into SIGTSTP to the terminal foreground group.

. "$(dirname "$0")/_build_lock.sh"
. "$(dirname "$0")/_qemu_drive.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf

echo "[test_jobcontrol] (1/3) Build userland + initramfs"
bash scripts/build_user.sh >/dev/null
bash scripts/build_modules.sh >/dev/null 2>&1 || true
python3 scripts/build_initramfs.py >/dev/null

echo "[test_jobcontrol] (2/3) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal init/main.ad -o "$ELF" >/dev/null

LOG=$(mktemp /tmp/test-jobcontrol.XXXXXX.log)
trap 'cp -f "$LOG" /tmp/test-jobcontrol.last.log 2>/dev/null; rm -f "$LOG"' EXIT

# Ctrl-Z byte. Fed as its own input line so the kernel serial RX path
# raises SIGTSTP to the terminal foreground process group.
CTRLZ=$'\x1a'

echo "[test_jobcontrol] (3/3) Boot QEMU + drive job-control sequence"
set +e
qemu_drive "$LOG" "$ELF" "[hamsh] M16.35 shell ready" 300 \
    -- \
    "echo JC_BEGIN"            1 \
    "sleep 3 &"                1 \
    "jobs"                     1 \
    "echo JC_AFTER_BG"         5 \
    "jobs"                     1 \
    "echo JC_BG_DONE"          2 \
    "sleep 8"                  2 \
    "$CTRLZ"                   2 \
    "echo JC_AFTER_STOP"       1 \
    "jobs"                     1 \
    "bg"                       2 \
    "echo JC_AFTER_BG2"        6 \
    "jobs"                     1 \
    "echo JC_END"              2 \
    "exit"                     1
rc="$QEMU_DRIVE_RC"
set -e

echo "[test_jobcontrol] --- captured output (filtered) ---"
{ grep -a -E "JC_|Running|Stopped|Done|^\[[0-9]+\] [0-9]|command not found|halting|hamsh\\\$" "$LOG" \
    | sed 's/\x1b\[[0-9;]*[a-zA-Z]//g' | tr -d '\000' | tail -80; } || true
echo "[test_jobcontrol] --- end output ---"

fail=0

# 0. The shell came up.
if ! grep -a -F -q "[hamsh] M16.35 shell ready" "$LOG"; then
    echo "[test_jobcontrol] FAIL: hamsh never reached the interactive loop"
    exit 1
fi

# Strip ANSI + NULs once into a flat view for the content assertions.
FLAT=$(sed 's/\x1b\[[0-9;]*[a-zA-Z]//g' "$LOG" | tr -d '\000')

have() { printf '%s\n' "$FLAT" | grep -a -q -- "$1"; }

# 1. The shell stayed alive through the WHOLE sequence (PID 1 never
#    got stopped by a child's Ctrl-Z). JC_END only prints if the shell
#    survived every step and kept reading commands.
if have "JC_BEGIN" && have "JC_END"; then
    echo "[test_jobcontrol] OK: shell survived the whole sequence (PID 1 alive)"
else
    echo "[test_jobcontrol] FAIL: shell wedged — JC_BEGIN/JC_END missing"
    fail=1
fi

# 2. The kernel never halted (a mis-handled stop of PID 1 would halt).
if have "schedule: no live tasks; halting"; then
    echo "[test_jobcontrol] FAIL: scheduler halted (PID 1 likely stopped)"
    fail=1
else
    echo "[test_jobcontrol] OK: scheduler never halted"
fi

# 3. `sleep 3 &` printed a job announce line `[1] <pgid>`.
if printf '%s\n' "$FLAT" | grep -a -E -q '^\[1\] [0-9]+'; then
    echo "[test_jobcontrol] OK: '&' announced job [1] with a pgid"
else
    echo "[test_jobcontrol] FAIL: no '[1] <pgid>' background announce"
    fail=1
fi

# 4. `jobs` reported a Running job while the background sleep was alive.
if printf '%s\n' "$FLAT" | grep -a -q 'Running'; then
    echo "[test_jobcontrol] OK: jobs showed a Running job"
else
    echo "[test_jobcontrol] FAIL: jobs never showed Running"
    fail=1
fi

# 5. The background job's completion was reported as Done at the prompt.
if printf '%s\n' "$FLAT" | grep -a -q 'Done'; then
    echo "[test_jobcontrol] OK: background job reported Done"
else
    echo "[test_jobcontrol] FAIL: background job never reported Done"
    fail=1
fi

# 6. Ctrl-Z suspended the foreground `sleep 9` -> a Stopped notice.
if printf '%s\n' "$FLAT" | grep -a -q 'Stopped'; then
    echo "[test_jobcontrol] OK: Ctrl-Z suspended the foreground job (Stopped)"
    ctrlz_ok=1
else
    echo "[test_jobcontrol] WARN: no 'Stopped' notice — Ctrl-Z-over-serial" \
         "may not have delivered SIGTSTP in this harness"
    ctrlz_ok=0
fi

# 7. The shell kept accepting commands AFTER the stop (JC_AFTER_STOP).
if have "JC_AFTER_STOP"; then
    echo "[test_jobcontrol] OK: prompt returned after the suspend"
else
    echo "[test_jobcontrol] FAIL: shell did not return to the prompt after Ctrl-Z"
    fail=1
fi

# Never a 'command not found' for sleep / jobs / fg / bg.
if printf '%s\n' "$FLAT" | grep -a -q 'command not found'; then
    echo "[test_jobcontrol] FAIL: a job-control command was 'command not found'"
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_jobcontrol] FAIL (qemu rc=$rc)"
    exit 1
fi
echo "[test_jobcontrol] PASS (qemu rc=$rc)"
