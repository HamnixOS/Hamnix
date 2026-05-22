#!/usr/bin/env bash
# scripts/test_hamsh_if.sh — hamsh `if { } else { }` (new shell).
#
# Ported from the old `if COND; then BODY; fi` test to the rewritten
# shell's C-style brace blocks (HAMSH_SPEC §5). test_hamsh_blocks.sh
# (§18 stage 3) covers MULTI-LINE if from the continuation prompt;
# this keeps the SINGLE-LINE interactive form covered:
#   1. `if 1 > 0 { echo IF_TRUE_PATH }`
#        → IF_TRUE_PATH appears (condition true → body runs)
#   2. `if 1 > 2 { echo IF_FALSE_PATH }`
#        → IF_FALSE_PATH must NOT appear (condition false → skip)
#   3. `if 0 > 1 { echo IFE_THEN } else { echo IFE_ELSE }`
#        → IFE_ELSE runs, IFE_THEN does not.
#   4. `echo POST_IF` → POST_IF appears (the shell survived).

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
    printf 'if 1 > 0 { echo IF_TRUE_PATH }\n'
    sleep 1
    printf 'if 1 > 2 { echo IF_FALSE_PATH }\n'
    sleep 1
    printf 'if 0 > 1 { echo IFE_THEN } else { echo IFE_ELSE }\n'
    sleep 1
    printf 'echo POST_IF\n'
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
# typed input, so a plain `grep` of the log would also match the command
# being typed. hamsh_ran (scripts/_hamsh_log.sh) ignores prompt-prefixed
# (input-echo) lines.
if hamsh_ran "$LOG" "IF_TRUE_PATH"; then
    echo "[test_hamsh_if] OK: if-true body executed"
else
    echo "[test_hamsh_if] MISS: if-true body did not run"
    fail=1
fi
if hamsh_ran "$LOG" "IF_FALSE_PATH"; then
    echo "[test_hamsh_if] MISS: if-false body leaked (should be skipped)"
    fail=1
else
    echo "[test_hamsh_if] OK: if-false body correctly skipped"
fi
if hamsh_ran "$LOG" "IFE_ELSE" && ! hamsh_ran "$LOG" "IFE_THEN"; then
    echo "[test_hamsh_if] OK: false condition took the else branch"
else
    echo "[test_hamsh_if] MISS: if/else branch selection wrong"
    fail=1
fi
if hamsh_ran "$LOG" "POST_IF"; then
    echo "[test_hamsh_if] OK: shell survived the if blocks"
else
    echo "[test_hamsh_if] MISS: shell did not survive (POST_IF absent)"
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_hamsh_if] --- captured ---"
    cat "$LOG"
    echo "[test_hamsh_if] --- end ---"
    echo "[test_hamsh_if] FAIL"
    exit 1
fi
echo "[test_hamsh_if] PASS"
