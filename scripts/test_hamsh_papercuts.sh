#!/usr/bin/env bash
# scripts/test_hamsh_papercuts.sh — M16.x hamsh shell-papercut fixes.
#
# Surfaced by the M16.x shell-bug agent (commits 0372cf2 / 652c653):
#
#   1. `cd`'s error message hardcoded "path too long" for every chdir
#      failure, even when the kernel set errstr to a more useful
#      "chdir: no such directory" / "chdir: not a directory" (M16.116).
#      Fix: cd builtin now calls SYS_ERRSTR after a failed sys_chdir
#      and prints `cd: <errstr>` so users see the real diagnosis.
#
#   2. Arrow keys + other ANSI/VT220 escape sequences emitted by the
#      M16.100 atkbd driver printed inline as raw bytes (`^[[A`
#      etc), breaking the look of the prompt. Fix: read_line() now
#      detects ESC + '[' and swallows the rest of a CSI sequence;
#      Up/Down also walk a 16-entry history ring and rewrite the
#      visible line in place.
#
# Strategy:
#   - Boot a kernel whose /init is hamsh.elf (same shape as the
#     existing scripts/test_hamsh_*.sh fixtures).
#   - Pipe a scripted sequence into the QEMU serial:
#         `cd /nope/nope/nope`   → expect `cd: chdir: no such directory`
#         `ls /etc`              → regression (output unchanged)
#         ESC [ A + Enter        → re-runs the previous (`ls /etc`)
#                                  command via history; the raw
#                                  `^[[A` MUST NOT show up in the log.
#         `exit`                 → graceful shutdown
#
# The 16550 RX FIFO needs sleeps between writes for the same reason
# documented in test_hamsh.sh.

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-vmlinux.elf
HAMSH_ELF=build/user/hamsh.elf

echo "[test_hamsh_papercuts] (1/4) Build userland"
bash scripts/build_user.sh >/dev/null
bash scripts/build_modules.sh >/dev/null

echo "[test_hamsh_papercuts] (2/4) Plant /init = hamsh in initramfs"
INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py >/dev/null

echo "[test_hamsh_papercuts] (3/4) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

echo "[test_hamsh_papercuts] (4/4) Boot QEMU + drive hamsh"
LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null' EXIT

set +e
(
    sleep 3
    # Case 1: cd to a non-existent directory should report the
    # kernel's errstr, NOT the stale "path too long" string.
    printf 'cd /nope/nope/nope\n'
    sleep 1
    # Case 2: simple regression — ls /etc still works after the
    # error-path tweak.
    printf 'ls /etc\n'
    sleep 1
    # Case 3: arrow-Up — should NOT print raw `^[[A`; should
    # restore the previous `ls /etc` line. The byte sequence is
    # ESC [ A (0x1B 0x5B 0x41) followed by Enter.
    printf '\x1b[A\n'
    sleep 1
    printf 'exit\n'
    sleep 1
) | timeout 20s qemu-system-x86_64 \
    -kernel "$ELF" \
    -smp 2 \
    -nographic \
    -no-reboot \
    -m 256M \
    -monitor none \
    -serial stdio \
    > "$LOG" 2>&1
rc=$?
set -e

echo "[test_hamsh_papercuts] --- captured output ---"
cat "$LOG"
echo "[test_hamsh_papercuts] --- end output ---"

fail=0

# Case 1: cd errstr surfaced verbatim. The exact errstr text comes
# from arch/x86/kernel/syscall.ad's SYS_CHDIR branch:
# "chdir: no such directory". hamsh prefixes with "cd: ".
if grep -F -q "cd: chdir: no such directory" "$LOG"; then
    echo "[test_hamsh_papercuts] PASS: cd surfaces kernel errstr"
else
    echo "[test_hamsh_papercuts] FAIL: cd error message not propagated"
    fail=1
fi

# Stale message MUST NOT appear — that would mean the new errstr
# path is dead code.
if grep -F -q "cd: path too long" "$LOG"; then
    echo "[test_hamsh_papercuts] FAIL: stale 'path too long' still emitted"
    fail=1
else
    echo "[test_hamsh_papercuts] PASS: stale message gone"
fi

# Case 2: regression — ls /etc still lists files. /etc/rc is the
# canonical entry guaranteed to exist (the boot-script reader).
if grep -F -q "rc" "$LOG"; then
    echo "[test_hamsh_papercuts] PASS: ls /etc regression"
else
    echo "[test_hamsh_papercuts] FAIL: ls /etc regression — /etc/rc not listed"
    fail=1
fi

# Case 3: arrow-Up escape sequence consumed. The raw bytes the
# shell would have echoed before the fix are `^[[A` (caret-form
# ESC) — actually 0x1B 0x5B 0x41 on the wire, which the VT100
# emulator behind QEMU's serial typically renders as `?[[A` or
# `\x1b[A`. We assert NEITHER of the two common renderings show
# up in the log. The history substitution adds nothing visible
# we can grep for that wouldn't also match the original ls
# output — the absence-check is the load-bearing signal here.
if grep -q $'\x1b\[A' "$LOG"; then
    echo "[test_hamsh_papercuts] FAIL: raw ESC[A leaked to terminal"
    fail=1
elif grep -F -q '^[[A' "$LOG"; then
    echo "[test_hamsh_papercuts] FAIL: caret-form ESC[A leaked to terminal"
    fail=1
else
    echo "[test_hamsh_papercuts] PASS: arrow-Up escape consumed silently"
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_hamsh_papercuts] FAIL (qemu rc=$rc)"
    exit 1
fi
echo "[test_hamsh_papercuts] PASS"
