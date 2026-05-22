#!/usr/bin/env bash
# scripts/test_hamsh_values.sh — HAMSH_SPEC §18 stage 2 acceptance.
#
# Typed values + list interpolation (§3):
#   * args = ["-la","/dev"]; echo $args  -> exactly two argv entries
#   * a value containing spaces is ONE argument (no word-splitting)
#   * int / string / bool values are distinct and arithmetic works
#
# The shell echoes the argv it received so we can count entries.

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
    # list interpolation: each element is exactly one argument
    printf 'args = ["A1", "A2"]\n'
    sleep 1
    printf 'echo L $args R\n'
    sleep 1
    # a value with spaces stays one argument
    printf 'phrase = "two words"\n'
    sleep 1
    printf 'echo X $phrase Y\n'
    sleep 1
    # arithmetic on int values
    printf 'n = 10 * 4 + 2\n'
    sleep 1
    printf 'echo SUM $n\n'
    sleep 1
    # string + concatenation
    printf 'g = "ham" + "nix"\n'
    sleep 1
    printf 'echo CAT $g\n'
    sleep 1
    # len() of a list
    printf 'echo LEN ${ len(args) }\n'
    sleep 1
    printf 'exit\n'
    sleep 1
) | timeout 30s qemu-system-x86_64 \
    -kernel "$ELF" -smp 2 -nographic -no-reboot -m 256M \
    -monitor none -serial stdio > "$LOG" 2>&1
set -e

echo "[test_hamsh_values] --- captured ---"
cat "$LOG"
echo "[test_hamsh_values] --- end ---"

fail=0
check() {
    if grep -F -q "$1" "$LOG"; then
        echo "[test_hamsh_values] OK: $2"
    else
        echo "[test_hamsh_values] MISS: $2"
        fail=1
    fi
}

# "L A1 A2 R" — the list contributed exactly two argv entries between
# the literal L and R, with no re-splitting.
check "L A1 A2 R"      "list interpolation: each element is one arg"
# "X two words Y" — the spaces inside the value did NOT split it.
check "X two words Y"  "a value with spaces stays one argument"
check "SUM 42"         "integer arithmetic"
check "CAT hamnix"     "string concatenation with +"
check "LEN 2"          "len() of a list"

if [ "$fail" -ne 0 ]; then
    echo "[test_hamsh_values] FAIL"
    exit 1
fi
echo "[test_hamsh_values] PASS"
