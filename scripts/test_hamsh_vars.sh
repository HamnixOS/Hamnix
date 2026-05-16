#!/usr/bin/env bash
# scripts/test_hamsh_vars.sh — M16.76 verification.
#
# Tests hamsh shell variables:
#   FOO=bar
#   echo $FOO         → "bar"
#   echo $MISSING     → "$MISSING" (literal — miss left untouched)
#   echo $?           → still the previous command's exit (separate)

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-vmlinux.elf
HAMSH_ELF=build/user/hamsh.elf

bash scripts/build_user.sh >/dev/null
INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py >/dev/null
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal init/main.ad -o "$ELF" >/dev/null

LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null' EXIT

set +e
(
    sleep 4
    printf 'FOO=hello\n'
    sleep 1
    printf 'echo VAR= $FOO\n'
    sleep 1
    printf 'echo MISS= $MISSING\n'
    sleep 1
    printf 'BAR=world\n'
    sleep 1
    printf 'echo BOTH= $FOO $BAR\n'
    sleep 1
    # M16.78: env builtin lists every defined variable.
    printf 'env\n'
    sleep 1
    # unset removes a variable; subsequent $FOO stays literal.
    printf 'unset FOO\n'
    sleep 1
    printf 'echo AFTER_UNSET= $FOO\n'
    sleep 1
    printf 'exit\n'
    sleep 1
) | timeout 22s qemu-system-x86_64 \
    -kernel "$ELF" \
    -smp 2 -nographic -no-reboot -m 256M -monitor none -serial stdio \
    > "$LOG" 2>&1
set -e

fail=0
if grep -F -q "VAR= hello" "$LOG"; then
    echo "[test_hamsh_vars] OK: \$FOO expanded to 'hello'"
else
    echo "[test_hamsh_vars] MISS: \$FOO expansion"
    fail=1
fi
if grep -F -q 'MISS= $MISSING' "$LOG"; then
    echo "[test_hamsh_vars] OK: undefined \$MISSING stayed literal"
else
    echo "[test_hamsh_vars] MISS: undefined-var handling"
    fail=1
fi
if grep -F -q "BOTH= hello world" "$LOG"; then
    echo "[test_hamsh_vars] OK: two-var expansion in one command"
else
    echo "[test_hamsh_vars] MISS: combined two-var expansion"
    fail=1
fi
# M16.78 env builtin — emits KEY=VALUE lines for every shell var.
if grep -F -q "FOO=hello" "$LOG" && grep -F -q "BAR=world" "$LOG"; then
    echo "[test_hamsh_vars] OK: env dumped both FOO and BAR"
else
    echo "[test_hamsh_vars] MISS: env didn't list both vars"
    fail=1
fi
# After unset FOO, $FOO becomes literal again.
if grep -F -q 'AFTER_UNSET= $FOO' "$LOG"; then
    echo "[test_hamsh_vars] OK: unset cleared FOO"
else
    echo "[test_hamsh_vars] MISS: unset didn't clear FOO"
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_hamsh_vars] --- captured ---"
    cat "$LOG"
    echo "[test_hamsh_vars] --- end ---"
    echo "[test_hamsh_vars] FAIL"
    exit 1
fi
echo "[test_hamsh_vars] PASS"
