#!/usr/bin/env bash
# scripts/test_hamsh_quotes.sh — M16.80 verification.
#
# Tests double-quoted strings in hamsh tokenize:
#   echo "hello world"          → 2 tokens (echo + "hello world")
#                                  emits "hello world" not "hello\nworld"
#   echo "a"b"c"                → glues quoted segments: 1 token "abc"
#   echo a "b c" d              → 4 tokens (a, "b c", d, but argv 0..3)

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
    printf 'echo "hello world"\n'
    sleep 1
    printf 'echo "FOO BAR"\n'
    sleep 1
    printf 'echo a "b c" d\n'
    sleep 1
    printf 'exit\n'
    sleep 1
) | timeout 18s qemu-system-x86_64 \
    -kernel "$ELF" \
    -smp 2 -nographic -no-reboot -m 256M -monitor none -serial stdio \
    > "$LOG" 2>&1
set -e

fail=0
if grep -F -q "hello world" "$LOG"; then
    echo "[test_hamsh_quotes] OK: \"hello world\" preserved as one token"
else
    echo "[test_hamsh_quotes] MISS: hello world not seen as one token"
    fail=1
fi
if grep -F -q "FOO BAR" "$LOG"; then
    echo "[test_hamsh_quotes] OK: \"FOO BAR\" preserved"
else
    echo "[test_hamsh_quotes] MISS: FOO BAR not preserved"
    fail=1
fi
if grep -F -q "a b c d" "$LOG"; then
    echo "[test_hamsh_quotes] OK: mixed quoted/unquoted joined by echo"
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
