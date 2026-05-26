#!/usr/bin/env bash
# scripts/test_hamsh_heartbeat.sh - the hamsh idle heartbeat lives.
#
# The interactive shell emits a periodic "[hamsh-alive] tick=N
# uptime=Ns" line from ed_readline's idle poll loop (see
# user/hamsh.ad's _hb_check_and_emit / _hb_emit_to_stderr). It is the
# canary for "shell is being scheduled at all" — without it, a
# regression where a kernel-mode syscall busy-loops without yielding
# (or a userland service hogs cycles) starves the shell, the user
# stops getting heartbeats, AND every test that drives input via the
# serial port stalls because the shell never reads anything.
#
# This silently regressed once already (per project memory's
# "regression-prone needs a test" rule), so it gets a dedicated CI
# test that boots the production rc.boot path (sshd + motd + ifconfig
# all running, which is the realistic load) and asserts at least
# three heartbeats reach the serial console within the boot window.
#
# Three rather than one because tick=0 fires almost instantly (the
# first ed_readline call seeds hb_inited), so the meaningful signal
# is that successive ticks (tick=1 at ~3 s, tick=2 at ~6 s, ...) DO
# follow — i.e. the idle loop keeps getting CPU.

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf

echo "[test_hamsh_heartbeat] (1/3) Build"
bash scripts/build_user.sh >/dev/null
bash scripts/build_modules.sh >/dev/null
python3 scripts/build_initramfs.py >/dev/null
python3 -m compiler.adder compile --target=x86_64-bare-metal \
    init/main.ad -o "$ELF" >/dev/null

echo "[test_hamsh_heartbeat] (2/3) Boot QEMU"
LOG=$(mktemp /tmp/hamsh-heartbeat.XXXXXX.log)
trap 'rm -f "$LOG"' EXIT

set +e
# 90 seconds of pure observation — production boot path with all
# services running. No input piped in: a fully idle interactive
# shell MUST still emit heartbeats. If it doesn't, a kernel busy-
# loop or a userland CPU hog is starving the prompt.
timeout 90s qemu-system-x86_64 \
    -kernel "$ELF" -smp 2 -nographic -no-reboot -m 256M \
    -monitor none -serial stdio < /dev/null > "$LOG" 2>&1
rc=$?
set -e

echo "[test_hamsh_heartbeat] (3/3) Assertions"

# Sanity: the prompt actually came up.
if ! grep -F -q "[hamsh:stage-07] loop-enter" "$LOG"; then
    echo "[test_hamsh_heartbeat] FAIL: hamsh never reached the interactive" \
         "loop (stage-07 marker absent — boot wedged before the prompt)"
    tail -50 "$LOG" | strings
    exit 1
fi

# Count distinct heartbeat ticks. We use grep with -c to count lines,
# and require >= 3 (covers boot-banner-tick + at least two periodic
# ticks at ~3 s cadence).
tick_count=$(grep -F -c "[hamsh-alive] tick=" "$LOG" || true)
echo "[test_hamsh_heartbeat] observed $tick_count heartbeat lines"

if [ "$tick_count" -lt 3 ]; then
    echo "[test_hamsh_heartbeat] FAIL: only $tick_count heartbeat lines" \
         "(need >= 3 within the 90 s window). Something is starving the" \
         "shell — check for kernel busy-loops and userland service hogs."
    echo "[test_hamsh_heartbeat] --- tail ---"
    tail -50 "$LOG" | strings
    exit 1
fi

# Also assert we see at least tick=1 and tick=2 specifically — if
# only tick=0 fires N times that's a different bug (corruption /
# loop without rearming) but still a regression.
if ! grep -F -q "[hamsh-alive] tick=1 " "$LOG"; then
    echo "[test_hamsh_heartbeat] FAIL: tick=1 never observed"
    exit 1
fi
if ! grep -F -q "[hamsh-alive] tick=2 " "$LOG"; then
    echo "[test_hamsh_heartbeat] FAIL: tick=2 never observed"
    exit 1
fi

echo "[test_hamsh_heartbeat] PASS (qemu rc=$rc, $tick_count ticks)"
