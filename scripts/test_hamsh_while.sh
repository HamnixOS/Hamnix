#!/usr/bin/env bash
# scripts/test_hamsh_while.sh — M16.85 verification.
#
# Exercises hamsh's new `else` clause on if/then/fi and the new
# `while COND ; do BODY ; done` loop (single-line forms, sharing
# the if_depth recursion cap with M16.84's if-block parser).
#
# Lines typed at the prompt:
#   1. `echo START`                                 → START present
#   2. `i=3`                                        → shell var set
#   3. `while test $i = 3 ; do echo LOOP_BODY ; i=NEXT ; done`
#        → loop iterates exactly once: body runs (i becomes NEXT),
#          next condition check fails (NEXT != 3), loop exits.
#          LOOP_BODY appears exactly once.
#   4. `echo POST_WHILE`                            → POST_WHILE present
#   5. `if true ; then echo IF_THEN_BODY ; else echo IF_ELSE_BODY ; fi`
#        → IF_THEN_BODY runs, IF_ELSE_BODY does NOT.
#   6. `if false ; then echo IF_THEN_FAIL ; else echo IF_ELSE_OK ; fi`
#        → IF_ELSE_OK runs, IF_THEN_FAIL does NOT.
#   7. `exit`                                       → clean shutdown

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
    printf 'echo START\n'
    sleep 1
    printf 'i=3\n'
    sleep 1
    printf 'while test $i = 3 ; do echo LOOP_BODY ; i=NEXT ; done\n'
    sleep 2
    printf 'echo POST_WHILE\n'
    sleep 1
    printf 'if true ; then echo IF_THEN_BODY ; else echo IF_ELSE_BODY ; fi\n'
    sleep 1
    printf 'if false ; then echo IF_THEN_FAIL ; else echo IF_ELSE_OK ; fi\n'
    sleep 1
    printf 'exit\n'
    sleep 1
) | timeout 25s qemu-system-x86_64 \
    -kernel "$ELF" \
    -smp 2 -nographic -no-reboot -m 256M -monitor none -serial stdio \
    > "$LOG" 2>&1
set -e

fail=0

# while: LOOP_BODY appears exactly once.
loop_count=$(grep -c -F "LOOP_BODY" "$LOG" || true)
if [ "$loop_count" -eq 1 ]; then
    echo "[test_hamsh_while] OK: while body ran exactly once"
else
    echo "[test_hamsh_while] MISS: LOOP_BODY count=$loop_count (expected 1)"
    fail=1
fi

# while: POST_WHILE present (shell survived the loop).
if grep -F -q "POST_WHILE" "$LOG"; then
    echo "[test_hamsh_while] OK: shell survived the while loop"
else
    echo "[test_hamsh_while] MISS: POST_WHILE absent (shell hung/crashed?)"
    fail=1
fi

# if/else: true → then branch.
if grep -F -q "IF_THEN_BODY" "$LOG"; then
    echo "[test_hamsh_while] OK: if true → then-body executed"
else
    echo "[test_hamsh_while] MISS: IF_THEN_BODY absent"
    fail=1
fi
if grep -F -q "IF_ELSE_BODY" "$LOG"; then
    echo "[test_hamsh_while] MISS: IF_ELSE_BODY leaked (true should skip else)"
    fail=1
else
    echo "[test_hamsh_while] OK: if true correctly skipped else-body"
fi

# if/else: false → else branch.
if grep -F -q "IF_ELSE_OK" "$LOG"; then
    echo "[test_hamsh_while] OK: if false → else-body executed"
else
    echo "[test_hamsh_while] MISS: IF_ELSE_OK absent"
    fail=1
fi
if grep -F -q "IF_THEN_FAIL" "$LOG"; then
    echo "[test_hamsh_while] MISS: IF_THEN_FAIL leaked (false should skip then)"
    fail=1
else
    echo "[test_hamsh_while] OK: if false correctly skipped then-body"
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_hamsh_while] --- captured ---"
    cat "$LOG"
    echo "[test_hamsh_while] --- end ---"
    echo "[test_hamsh_while] FAIL"
    exit 1
fi
echo "[test_hamsh_while] PASS"
