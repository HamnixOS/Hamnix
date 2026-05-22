#!/usr/bin/env bash
# scripts/test_hamsh_logic.sh — hamsh `&&` / `||` / `;` (new shell).
#
# Ported to the rewritten shell. The `&&` / `||` command chaining and
# `;` statement separator are unchanged surface between the old and
# new shells, but no §18 stage test covers them — this one does:
#   true && echo AFTER_AND_TRUE      → executes
#   false && echo AFTER_AND_FALSE    → skipped
#   true || echo AFTER_OR_TRUE       → skipped
#   false || echo AFTER_OR_FALSE     → executes
#   echo SEQ1 ; echo SEQ2            → both execute (`;` separates stmts)
#   false ; echo AFTER_SEMI          → executes (`;` ignores prev exit)

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
    printf 'true && echo AFTER_AND_TRUE\n'
    sleep 1
    printf 'false && echo AFTER_AND_FALSE\n'
    sleep 1
    printf 'true || echo AFTER_OR_TRUE\n'
    sleep 1
    printf 'false || echo AFTER_OR_FALSE\n'
    sleep 1
    printf 'echo SEQ1 ; echo SEQ2\n'
    sleep 1
    printf 'false ; echo AFTER_SEMI\n'
    sleep 1
    printf 'exit\n'
    sleep 1
) | timeout 22s qemu-system-x86_64 \
    -kernel "$ELF" \
    -smp 2 -nographic -no-reboot -m 256M -monitor none -serial stdio \
    > "$LOG" 2>&1
set -e

fail=0
check_present() {
    local needle="$1"
    if grep -F -q "$needle" "$LOG"; then
        echo "[test_hamsh_logic] OK: $needle present"
    else
        echo "[test_hamsh_logic] MISS: $needle absent"
        fail=1
    fi
}
check_absent() {
    local needle="$1"
    if grep -F -q "$needle" "$LOG"; then
        echo "[test_hamsh_logic] MISS: $needle leaked (should be skipped)"
        fail=1
    else
        echo "[test_hamsh_logic] OK: $needle correctly skipped"
    fi
}
check_present "AFTER_AND_TRUE"
check_absent  "AFTER_AND_FALSE"
check_absent  "AFTER_OR_TRUE"
check_present "AFTER_OR_FALSE"
check_present "SEQ1"
check_present "SEQ2"
check_present "AFTER_SEMI"

if [ "$fail" -ne 0 ]; then
    echo "[test_hamsh_logic] --- captured ---"
    cat "$LOG"
    echo "[test_hamsh_logic] --- end ---"
    echo "[test_hamsh_logic] FAIL"
    exit 1
fi
echo "[test_hamsh_logic] PASS"
