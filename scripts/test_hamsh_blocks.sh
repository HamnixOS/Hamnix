#!/usr/bin/env bash
# scripts/test_hamsh_blocks.sh — HAMSH_SPEC §18 stage 3 acceptance.
#
# Brace blocks + control flow + def (§5):
#   * multi-line if / for / while parse from the continuation prompt
#   * a def'd function runs with parameters
#   * mismatched braces error cleanly (no crash, parse error reported)
#
# hamsh has C-style { } blocks, no significant indentation; the parser
# knows a block is incomplete until the closing }, which is what makes
# both paste and the continuation prompt work.

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
    # multi-line if from the continuation prompt
    printf 'if 5 > 2 {\necho IF_TRUE_BRANCH\n} else {\necho IF_FALSE_BRANCH\n}\n'
    sleep 2
    # multi-line for loop
    printf 'for w in ["p", "q", "r"] {\necho FOR_ITEM $w\n}\n'
    sleep 2
    # multi-line while loop
    printf 'c = 0\n'
    sleep 1
    printf 'while c < 2 {\necho WHILE_ITER $c\nc = c + 1\n}\n'
    sleep 2
    # def + call
    printf 'def dbl(v) {\nreturn v + v\n}\n'
    sleep 2
    printf 'echo DEF_RESULT ${ dbl(21) }\n'
    sleep 1
    # mismatched braces: must report a clean parse error, not crash
    printf 'echo BEFORE_BADBRACE\n'
    sleep 1
    printf 'if 1 > 0 { echo UNCLOSED\n'
    sleep 1
    printf '}\n'
    sleep 1
    printf 'echo AFTER_BADBRACE\n'
    sleep 1
    printf 'exit\n'
    sleep 1
) | timeout 35s qemu-system-x86_64 \
    -kernel "$ELF" -smp 2 -nographic -no-reboot -m 256M \
    -monitor none -serial stdio > "$LOG" 2>&1
set -e

echo "[test_hamsh_blocks] --- captured ---"
cat "$LOG"
echo "[test_hamsh_blocks] --- end ---"

fail=0
# Assert on command OUTPUT only — hamsh's interactive line editor echoes
# typed input, so a plain `grep` of the log would also match the command
# being typed. hamsh_ran (scripts/_hamsh_log.sh) ignores the prompt-
# prefixed input-echo lines.
check() {
    if hamsh_ran "$LOG" "$1"; then
        echo "[test_hamsh_blocks] OK: $2"
    else
        echo "[test_hamsh_blocks] MISS: $2"
        fail=1
    fi
}

check "IF_TRUE_BRANCH"   "multi-line if parses from continuation prompt"
check "FOR_ITEM p"       "multi-line for: first item"
check "FOR_ITEM r"       "multi-line for: last item"
check "WHILE_ITER 0"     "multi-line while: first iteration"
check "WHILE_ITER 1"     "multi-line while: second iteration"
check "DEF_RESULT 42"    "def function runs with a parameter"
# the shell must survive a mismatched-brace input cleanly
check "AFTER_BADBRACE"   "shell survives mismatched braces (no crash)"

# the false branch must NOT run
if hamsh_ran "$LOG" "IF_FALSE_BRANCH"; then
    echo "[test_hamsh_blocks] MISS: false branch leaked"
    fail=1
else
    echo "[test_hamsh_blocks] OK: false branch correctly skipped"
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_hamsh_blocks] FAIL"
    exit 1
fi
echo "[test_hamsh_blocks] PASS"
