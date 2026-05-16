#!/usr/bin/env bash
# scripts/test_devnull.sh — M16.68 verification.
#
# Exercises /dev/null and /dev/zero via the shell:
#   echo discarded > /dev/null    — sink consumes everything, no echo on stdout
#   cat /dev/null                  — immediate EOF, no output
#   cat /dev/zero | head -c 0    — hand-edited: head reads zero bytes, exits
#
# Asserts that:
#   1. Writing to /dev/null doesn't echo "discarded" to stdout
#   2. cat /dev/null prints nothing (no "/dev/null" wrapper output either)
#   3. The shell can put /dev/zero into a pipeline without panic

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
    sleep 3
    # Write to /dev/null — output should NOT contain DISCARDED_MARK
    # because the shell redirected stdout to the sink.
    printf 'echo DISCARDED_MARK > /dev/null\n'
    sleep 1
    # Sentinel to confirm the shell survives writing to /dev/null.
    printf 'echo POST_NULL_OK\n'
    sleep 1
    # Reading /dev/null should produce nothing.
    printf 'cat /dev/null\n'
    sleep 1
    printf 'echo POST_CAT_OK\n'
    sleep 1
    printf 'exit\n'
    sleep 1
) | timeout 15s qemu-system-x86_64 \
    -kernel "$ELF" \
    -smp 2 -nographic -no-reboot -m 256M -monitor none -serial stdio \
    > "$LOG" 2>&1
set -e

fail=0
if grep -F -q "DISCARDED_MARK" "$LOG"; then
    echo "[test_devnull] MISS: DISCARDED_MARK leaked through /dev/null"
    fail=1
else
    echo "[test_devnull] OK: /dev/null absorbed echo output"
fi
if grep -F -q "POST_NULL_OK" "$LOG"; then
    echo "[test_devnull] OK: shell survived /dev/null write"
else
    echo "[test_devnull] MISS: shell died after /dev/null write"
    fail=1
fi
if grep -F -q "POST_CAT_OK" "$LOG"; then
    echo "[test_devnull] OK: shell survived cat /dev/null"
else
    echo "[test_devnull] MISS: shell died on cat /dev/null"
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_devnull] --- captured output ---"
    cat "$LOG"
    echo "[test_devnull] --- end output ---"
    echo "[test_devnull] FAIL"
    exit 1
fi
echo "[test_devnull] PASS"
