#!/usr/bin/env bash
# scripts/test_linux_interactive_tty.sh — #164: console keystrokes reach
# an interactive `enter linux { /bin/sh }` guest's stdin, are echoed, and
# the guest runs the typed command.
#
# THE BUG THIS GUARDS
#
# Before #164 a Linux-namespace binary launched interactively from the
# local console (`enter linux { /bin/sh }`, no `-c`) could not be used:
# typing on the controlling terminal never produced an echo and the
# guest's read(2) on fd 0 got raw, un-cooked bytes (TCGETS reported an
# all-zero termios = ICANON off / ECHO off). The only interactive path
# that worked was sshd's own pty. This made an interactive Debian /bin/sh,
# bash, or python3 REPL on the console unusable.
#
# THE FIX
#
# linux_abi/u_termios.ad gives every task a real per-task termios state
# (cooked default: ICANON|ECHO|ECHOE|ICRNL) and a line discipline that
# echoes + cooks console input. linux_abi/u_syscalls.ad routes a blocking
# read(2) on a console-backed fd through it, and TCGETS/TCSETS now read &
# apply that real state. fs/vfs.ad::vfs_fd_is_console identifies the
# console-backed fd (FD_STDIN/FD_CONS or an /fd/N → DEVFD_CONS bind — the
# exact stdio shape every `enter linux { … }` guest inherits).
#
# WHAT THIS TEST PROVES (the honesty bar)
#
# The proof is GUEST-SIDE CONSUMPTION: we launch an INTERACTIVE busybox
# /bin/sh (no `-c`), then feed `echo <MARKER>` + newline to the SAME serial
# RX FIFO that real keystrokes land in. The guest's own read(0) must pull
# that line through the cooked discipline and RUN it — the marker only
# appears if the guest actually consumed fd 0. We separately assert the
# discipline ECHOED the typed bytes back to the console (cooked-mode echo).
#
# COVERAGE BOUNDARY (documented, not hidden)
#
#  * Drives input through the UART RX FIFO (uart_rx_pop) — the identical
#    path a real serial/PS2 keystroke takes into devcons_read_nb. It does
#    NOT exercise PS/2 scancode decode (that is atkbd.ad's concern and is
#    already covered elsewhere); the byte source past the FIFO is shared.
#  * Ctrl-C/Ctrl-Z (SIGINT/SIGTSTP) are intercepted at the FIFO drain
#    BELOW this layer and are covered by the existing signal/job-control
#    tests — not re-proven here.

. "$(dirname "$0")/_build_lock.sh"
. "$(dirname "$0")/_ensure_ubin.sh"
. "$(dirname "$0")/_qemu_drive.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf

ensure_ubin_or_skip test_linux_interactive_tty u_busybox_musl musl_busybox

echo "[test_linux_interactive_tty] (1/4) Build userland + modules"
bash scripts/build_user.sh >/dev/null
bash scripts/build_modules.sh >/dev/null

echo "[test_linux_interactive_tty] (2/4) Build default initramfs"
python3 scripts/build_initramfs.py >/dev/null

echo "[test_linux_interactive_tty] (3/4) Rebuild kernel image"
mkdir -p build
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

echo "[test_linux_interactive_tty] (4/4) Boot QEMU + drive an INTERACTIVE guest sh"

LOG=$(mktemp)
trap 'rm -f "$LOG"' EXIT

# Sequence:
#   1. `enter linux { /bin/sh }`  — launch the guest INTERACTIVELY (no -c).
#      hamsh blocks in waitpid; the guest is now the foreground reader of
#      the console. The post-delay gives the guest time to reach its first
#      read(0).
#   2. type `echo IN_$((21+21))_OK`  — these bytes flow into the UART RX
#      FIFO exactly as a keystroke would; the guest's cooked read(0) must
#      assemble + echo + return the line, and busybox `sh` runs it.
#      CRUCIAL: the OUTPUT (`IN_42_OK`) is NOT a substring of the typed
#      source (`echo IN_$((21+21))_OK`). Only a real POSIX `sh` that
#      EVALUATED the arithmetic prints `IN_42_OK`. hamsh cannot — it has
#      no `$((…))` and would error "command not found" on the line. So
#      `IN_42_OK` in the log is unforgeable proof the GUEST consumed fd 0
#      and ran the command (the honesty bar): it can only come from the
#      guest shell, never from a local echo of the keystrokes.
#   3. type `exit`  — the guest leaves; control returns to hamsh.
#   4. hamsh `exit`.
# NB: the kernel task table is small (NTASKS=16). At the instant the
# banner prints, the boot's detached services (VT2..VT4 gettys, motd,
# ifconfig, ntpd) are still occupying task slots and have NOT yet
# self-reaped. `enter linux` forks a hamsh child + execs busybox, which
# needs free slots — so we let the boot QUIESCE first: a leading no-op
# `/uname` (native, one slot, returns instantly) with a long post-delay
# gives the detached services time to exit + self-reap before we launch
# the interactive guest. Without this settle the guest spawn races the
# boot services and hits "create_user_task: no free task slot".
set +e
qemu_drive "$LOG" "$ELF" "[hamsh] M16.35 shell ready" 90 \
    -- '/uname' 12 \
       'enter linux { /bin/sh }' 6 \
       'echo IN_$((21+21))_OK' 5 \
       'exit' 3 \
       'exit' 1
rc="$QEMU_DRIVE_RC"
set -e

echo "[test_linux_interactive_tty] --- captured output ---"
cat "$LOG"
echo "[test_linux_interactive_tty] --- end output ---"

fail=0

# (a) GUEST CONSUMPTION (load-bearing): `IN_42_OK` only exists if a real
#     POSIX `sh` evaluated `$((21+21))`. It is NOT in the typed source
#     text, so it cannot come from a local echo of the keystrokes — the
#     guest's own read(0) pulled the line through the cooked discipline
#     and busybox ran it. This is the honesty-bar assertion.
if grep -a -F -q "IN_42_OK" "$LOG"; then
    echo "[test_linux_interactive_tty] OK: guest consumed fd 0 + ran the typed command"
else
    echo "[test_linux_interactive_tty] FAIL: IN_42_OK not seen —" \
         "guest never read/ran the keystrokes from fd 0"
    fail=1
fi

# (b) COOKED ECHO: the termios discipline echoed the typed command back to
#     the console as it was typed. The literal source text `echo IN_` (the
#     start of the typed line, which appears in NO boot banner) shows up
#     only because the discipline echoed the keystrokes — without the
#     cooked-mode echo the typed bytes would be invisible.
if grep -a -F -q "echo IN_" "$LOG"; then
    echo "[test_linux_interactive_tty] OK: cooked-mode echo surfaced the typed line"
else
    echo "[test_linux_interactive_tty] FAIL: typed command never echoed —" \
         "line discipline echo not working"
    fail=1
fi

# (c) no kernel trap / page fault during the interactive session.
if grep -a -F -q "TRAP: vector" "$LOG"; then
    echo "[test_linux_interactive_tty] DIAG: CPU exception observed"
    grep -a -F "TRAP: vector" "$LOG" | head -5 || true
    fail=1
fi
if grep -a -F -q "page fault" "$LOG"; then
    echo "[test_linux_interactive_tty] DIAG: page fault observed"
    grep -a -F "page fault" "$LOG" | head -5 || true
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_linux_interactive_tty] FAIL (qemu rc=$rc)"
    exit 1
fi

echo "[test_linux_interactive_tty] PASS — interactive console keystrokes" \
     "reach the Linux guest's stdin, are cooked + echoed, and run (IN_42_OK)"
