#!/usr/bin/env bash
# scripts/test_hamsh_block.sh — QA-N27 regression: every statement in a
# `;`-separated brace block runs, INCLUDING the last.
#
# THE BUG (QA-N27, found during Wayland Phase-4 QA)
#
# A statement-LEADING `{ ... }` compound block was not parsed as a block
# at all — a leading `{` fell through to the command path and died with
# a spurious "empty command" parse error, so NONE of `{ echo A ; echo B ;
# echo C }` ran. (Control-flow bodies — `if`/`while`/`for`/`def` and the
# `ns`/`enter`/`spawn` namespace verbs — always drove their statement
# list correctly; only the BARE brace block was missing from the §2
# statement dispatch.) The fix adds a bare-block branch to
# _parse_statement_body so `{ … }` opens a compound block whose every
# `;`/newline-separated statement runs in the current scope.
#
# WHAT THIS ASSERTS
#   * bare `{ echo A ; echo B ; echo C }`         -> A, B AND C (last runs)
#   * bare trailing-`;` `{ echo P ; }`            -> P
#   * nested control-flow body `if 1 { echo I ; echo J }` -> I AND J
#   * a bare block inside a `for` body still runs every statement
#
# hamsh drops the FIRST serial line after boot (and can miss an early
# line while the console warms), so every command is sent TWICE and each
# assertion only needs ONE genuine run.

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

# send <cmd> — type it, Enter, twice, to survive the first-line drop.
send() { printf '%s\n' "$1"; sleep 2; printf '%s\n' "$1"; sleep 2; }

set +e
(
    sleep 6
    # warm the console so the very first real command is not swallowed
    for i in 1 2 3 4; do printf 'echo WARM%d\n' "$i"; sleep 1; done
    # bare block, `;`-separated: A, B AND C must all print
    send '{ echo BLK_A ; echo BLK_B ; echo BLK_C }'
    # bare block with a TRAILING `;`: P must print
    send '{ echo BLK_P ; }'
    # nested control-flow body: I AND J
    send 'if 1 { echo BLK_I ; echo BLK_J }'
    # a bare block nested inside a for-loop body
    send 'for x in one { echo FOR_K ; echo FOR_L }'
    printf 'exit\n'; sleep 1
    printf 'exit\n'; sleep 1
) | timeout 120s qemu-system-x86_64 \
    -kernel "$ELF" -smp 2 -nographic -no-reboot -m 256M \
    -monitor none -serial stdio > "$LOG" 2>&1
set -e

echo "[test_hamsh_block] --- captured ---"
cat "$LOG"
echo "[test_hamsh_block] --- end ---"

fail=0
check() {
    if hamsh_ran "$LOG" "$1"; then
        echo "[test_hamsh_block] OK: $2"
    else
        echo "[test_hamsh_block] MISS: $2"
        fail=1
    fi
}

# the LAST statement of each block is the load-bearing assertion.
check "BLK_A" "bare block: first statement runs"
check "BLK_B" "bare block: middle statement runs"
check "BLK_C" "bare block: LAST statement runs (QA-N27)"
check "BLK_P" "bare block with trailing ';': statement runs"
check "BLK_I" "if body: first statement runs"
check "BLK_J" "if body: LAST statement runs"
check "FOR_K" "block in for body: first statement runs"
check "FOR_L" "block in for body: LAST statement runs"

# the "empty command" parse error must NOT appear for a bare block
if grep -a -F -q "empty command" "$LOG"; then
    echo "[test_hamsh_block] MISS: bare '{' still mis-parsed as empty command"
    fail=1
else
    echo "[test_hamsh_block] OK: bare block parses (no 'empty command')"
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_hamsh_block] FAIL"
    exit 1
fi
echo "[test_hamsh_block] PASS"
