#!/usr/bin/env bash
# scripts/test_hamsh_dispatch.sh — HAMSH_SPEC §18 stage 1 acceptance.
#
# Statement dispatch (§2): a corpus of lines classifies deterministically
# as command / assignment / control by the first-token rule. ${ } and
# `{ } nest correctly. No line is ambiguous.
#
# Drives the new hamsh and asserts each input produced the right kind of
# behaviour:
#   * `ls -la /dev`     -> command   (bare words are literal string args)
#   * `x = 8080`        -> assignment (no command spawned)
#   * `if true { ... }` -> control construct
#   * `${ }` / `` `{ }`` nest inside an interpolating string.

. "$(dirname "$0")/_build_lock.sh"

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
    # command statement: bare words are literal string args
    printf 'echo CMD_OK alpha beta\n'
    sleep 1
    # assignment statement: must NOT spawn a command
    printf 'k = 42\n'
    sleep 1
    printf 'echo ASSIGN_VAL $k\n'
    sleep 1
    # control construct
    printf 'if true {\necho CONTROL_OK\n}\n'
    sleep 2
    # ${ } nested expression interpolation
    printf 'echo NEST ${ 6 * 7 }\n'
    sleep 1
    # nested ${ } inside another expression
    printf 'echo DEEP ${ 2 + ${ 3 * 3 } }\n'
    sleep 1
    printf 'exit\n'
    sleep 1
) | timeout 30s qemu-system-x86_64 \
    -kernel "$ELF" -smp 2 -nographic -no-reboot -m 256M \
    -monitor none -serial stdio > "$LOG" 2>&1
set -e

echo "[test_hamsh_dispatch] --- captured ---"
cat "$LOG"
echo "[test_hamsh_dispatch] --- end ---"

fail=0
check() {
    if grep -F -q "$1" "$LOG"; then
        echo "[test_hamsh_dispatch] OK: $2"
    else
        echo "[test_hamsh_dispatch] MISS: $2"
        fail=1
    fi
}

check "CMD_OK alpha beta"  "command statement: bare words are literal args"
check "ASSIGN_VAL 42"      "assignment statement classified, value bound"
check "CONTROL_OK"         "control construct (if) classified"
check "NEST 42"            '${ } expression interpolation evaluated'
check "DEEP 11"            'nested ${ } interpolation evaluated'

if [ "$fail" -ne 0 ]; then
    echo "[test_hamsh_dispatch] FAIL"
    exit 1
fi
echo "[test_hamsh_dispatch] PASS"
