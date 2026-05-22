#!/usr/bin/env bash
# scripts/test_hamsh_quotes.sh — hamsh quoting (new shell, HAMSH_SPEC §4).
#
# Ported to the rewritten shell. No §18 stage test covers quoting on
# its own, so this one does:
#   * `echo "hello world"` — a double-quoted word with a space is ONE
#     argument (no word-splitting — the §3 list rule's sibling).
#   * `echo "$who there"` — double quotes interpolate `$`.
#   * `echo '$who literal'` — single quotes are literal: no interpolation.
#   * `echo a "b c" d` — mixed quoted/bare words; echo joins with spaces.

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
    printf 'echo "hello world"\n'
    sleep 1
    printf 'who = "ham"\n'
    sleep 1
    printf 'echo "$who there"\n'
    sleep 1
    printf "echo '\$who literal'\n"
    sleep 1
    printf 'echo a "b c" d\n'
    sleep 1
    printf 'exit\n'
    sleep 1
) | timeout 20s qemu-system-x86_64 \
    -kernel "$ELF" \
    -smp 2 -nographic -no-reboot -m 256M -monitor none -serial stdio \
    > "$LOG" 2>&1
set -e

fail=0
if grep -F -q "hello world" "$LOG"; then
    echo "[test_hamsh_quotes] OK: \"hello world\" preserved as one argument"
else
    echo "[test_hamsh_quotes] MISS: hello world not preserved"
    fail=1
fi
if grep -F -q "ham there" "$LOG"; then
    echo "[test_hamsh_quotes] OK: double quotes interpolate \$who"
else
    echo "[test_hamsh_quotes] MISS: double-quote interpolation failed"
    fail=1
fi
if grep -F -q '$who literal' "$LOG"; then
    echo "[test_hamsh_quotes] OK: single quotes are literal (no interpolation)"
else
    echo "[test_hamsh_quotes] MISS: single quote interpolated or dropped"
    fail=1
fi
if grep -F -q "a b c d" "$LOG"; then
    echo "[test_hamsh_quotes] OK: mixed quoted/bare words joined by echo"
else
    echo "[test_hamsh_quotes] MISS: mixed echo output"
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_hamsh_quotes] --- captured ---"
    cat "$LOG"
    echo "[test_hamsh_quotes] --- end ---"
    echo "[test_hamsh_quotes] FAIL"
    exit 1
fi
echo "[test_hamsh_quotes] PASS"
