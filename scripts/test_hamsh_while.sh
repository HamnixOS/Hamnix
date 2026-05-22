#!/usr/bin/env bash
# scripts/test_hamsh_while.sh — hamsh `while { }` loop (new shell).
#
# Ported from the old `while COND; do BODY; done` test to the
# rewritten shell's C-style brace blocks (HAMSH_SPEC §5). Where
# test_hamsh_blocks.sh (§18 stage 3) parses a multi-line while, this
# keeps the EXACT-ITERATION-COUNT behaviour covered: a while whose
# condition stops being true after the body mutates the counter must
# run its body a precise number of times, then exit.
#
# Lines typed at the prompt:
#   1. `echo START`                       → START present
#   2. `i = 0`                            → assignment, no command
#   3. `while i < 3 { echo LOOP_BODY ; i = i + 1 }`
#        → body runs exactly 3 times (i: 0,1,2), then i==3 stops it.
#   4. `echo POST_WHILE I=${ i }`         → I=3, shell survived

. "$(dirname "$0")/_build_lock.sh"
. "$(dirname "$0")/_hamsh_log.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf

bash scripts/build_user.sh >/dev/null
INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py >/dev/null
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal init/main.ad -o "$ELF" >/dev/null

LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null' EXIT

set +e
(
    sleep 3
    printf 'echo START\n'
    sleep 1
    printf 'i = 0\n'
    sleep 1
    printf 'while i < 3 { echo LOOP_BODY ; i = i + 1 }\n'
    sleep 2
    printf 'echo POST_WHILE final ${ i }\n'
    sleep 1
    printf 'exit\n'
    sleep 1
) | timeout 25s qemu-system-x86_64 \
    -kernel "$ELF" \
    -smp 2 -nographic -no-reboot -m 256M -monitor none -serial stdio \
    > "$LOG" 2>&1
set -e

fail=0

# Assert on command OUTPUT only — hamsh's interactive line editor echoes
# typed input, so a plain `grep` of the log would also count the
# `while ... { echo LOOP_BODY ... }` line as it is typed. hamsh_ran_count
# (scripts/_hamsh_log.sh) ignores the prompt-prefixed input-echo lines.
loop_count=$(hamsh_ran_count "$LOG" "LOOP_BODY")
if [ "${loop_count:-0}" -eq 3 ]; then
    echo "[test_hamsh_while] OK: while body ran exactly three times"
else
    echo "[test_hamsh_while] MISS: LOOP_BODY count=$loop_count (expected 3)"
    fail=1
fi

# while: counter has the post-loop value (shell survived the loop).
if hamsh_ran "$LOG" "POST_WHILE final 3"; then
    echo "[test_hamsh_while] OK: shell survived; counter ended at 3"
else
    echo "[test_hamsh_while] MISS: POST_WHILE final 3 absent (loop hung/wrong count)"
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_hamsh_while] --- captured ---"
    cat "$LOG"
    echo "[test_hamsh_while] --- end ---"
    echo "[test_hamsh_while] FAIL"
    exit 1
fi
echo "[test_hamsh_while] PASS"
