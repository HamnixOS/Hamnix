#!/usr/bin/env bash
# scripts/test_hamsh_if.sh — M16.83 verification.
#
# Exercises hamsh's `if COND ; then BODY ; fi` construct
# (single-line form, no else). Three lines are typed:
#   1. `if true;  then echo IF_TRUE_PATH;  fi`
#        → IF_TRUE_PATH should appear (condition true → body runs)
#   2. `if false; then echo IF_FALSE_PATH; fi`
#        → IF_FALSE_PATH must NOT appear (condition false → skip)
#   3. `echo POST_IF`
#        → POST_IF must appear (the shell survived both ifs).

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
    sleep 3
    printf 'if true; then echo IF_TRUE_PATH; fi\n'
    sleep 1
    printf 'if false; then echo IF_FALSE_PATH; fi\n'
    sleep 1
    printf 'echo POST_IF\n'
    sleep 1
    printf 'exit\n'
    sleep 1
) | timeout 20s qemu-system-x86_64 \
    -kernel "$ELF" \
    -smp 2 -nographic -no-reboot -m 256M -monitor none -serial stdio \
    > "$LOG" 2>&1
set -e

fail=0
if grep -F -q "IF_TRUE_PATH" "$LOG"; then
    echo "[test_hamsh_if] OK: if-true body executed"
else
    echo "[test_hamsh_if] MISS: if-true body did not run"
    fail=1
fi
if grep -F -q "IF_FALSE_PATH" "$LOG"; then
    echo "[test_hamsh_if] MISS: if-false body leaked (should be skipped)"
    fail=1
else
    echo "[test_hamsh_if] OK: if-false body correctly skipped"
fi
if grep -F -q "POST_IF" "$LOG"; then
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
