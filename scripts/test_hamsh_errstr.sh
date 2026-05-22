#!/usr/bin/env bash
# scripts/test_hamsh_errstr.sh — HAMSH_SPEC §18 stage 11 acceptance.
#
# errstr / try-catch (§16):
#   * Error handling is wired to the kernel's Plan 9 errstr mechanism
#     — NOT a reinvented $? + set -e.
#   * `$errstr` is a native variable holding the last failure string.
#   * Every command yields an exit status AND an errstr.
#   * `try { } except { }` is built on errstr: a failing command in
#     the try block runs the except block, and $errstr carries the
#     kernel's message into it.
#
# A failing `mount` (no live 9P server, so sys_mount rejects the bad
# srvfd) is the canonical caught failure.

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
    # A failing mount caught by try/except; $errstr carries the message.
    printf 'echo TRYTEST\n'
    sleep 1
    printf 'try {\nmount 9 /n/nowhere\n} except {\necho CAUGHT $errstr\n}\n'
    sleep 3
    # A try block whose body SUCCEEDS must NOT run the except block.
    printf 'try {\necho TRY_OK_BODY\n} except {\necho SHOULD_NOT_RUN\n}\n'
    sleep 2
    # $errstr is a readable native variable after a failing command.
    printf 'unmount /not/mounted/anywhere\n'
    sleep 1
    printf 'echo ERRSTR_VAR $errstr\n'
    sleep 1
    printf 'echo DONE\n'
    sleep 1
    printf 'exit\n'
    sleep 1
) | timeout 55s qemu-system-x86_64 \
    -kernel "$ELF" -smp 2 -nographic -no-reboot -m 256M \
    -monitor none -serial stdio > "$LOG" 2>&1
set -e

echo "[test_hamsh_errstr] --- captured ---"
cat "$LOG"
echo "[test_hamsh_errstr] --- end ---"

fail=0

# The failing mount was caught — the except block ran.
if grep -F -q "CAUGHT " "$LOG"; then
    echo "[test_hamsh_errstr] OK: failing command caught by try/except"
else
    echo "[test_hamsh_errstr] MISS: try/except did not catch the failure"
    fail=1
fi

# $errstr carried the kernel's message into the except block — the
# CAUGHT line must have a non-empty errstr payload (kernel mount error).
caught_line=$(grep -F "CAUGHT " "$LOG" | head -1)
if echo "$caught_line" | grep -E -q "CAUGHT .*mount"; then
    echo "[test_hamsh_errstr] OK: \$errstr carries the kernel's failure message"
else
    echo "[test_hamsh_errstr] MISS: \$errstr empty / not the kernel message"
    echo "        (caught line: '$caught_line')"
    fail=1
fi

# A successful try body must NOT trigger the except block.
if grep -F -q "TRY_OK_BODY" "$LOG" && ! grep -F -q "SHOULD_NOT_RUN" "$LOG"; then
    echo "[test_hamsh_errstr] OK: successful try body skips the except block"
else
    echo "[test_hamsh_errstr] MISS: except block ran for a successful try"
    fail=1
fi

# $errstr is a readable native variable after a failing command.
if grep -E -q "ERRSTR_VAR .*mount" "$LOG"; then
    echo "[test_hamsh_errstr] OK: \$errstr native variable holds the last failure"
else
    echo "[test_hamsh_errstr] MISS: \$errstr native variable empty"
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_hamsh_errstr] FAIL"
    exit 1
fi
echo "[test_hamsh_errstr] PASS"
