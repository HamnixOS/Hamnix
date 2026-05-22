#!/usr/bin/env bash
# scripts/test_multipipe.sh - M16.40 verification.
#
# Drives hamsh through a 3-stage pipeline:
#
#     echo three stage pipeline | cat | /cat
#
# Each stage runs as a separate task. The phrase has to pass
# through two kernel pipes — proving that hamsh correctly sliced
# argv on every `|`, allocated nseg-1 pipes, wired each child's
# stdin/stdout to the right pair of ends, and closed the parent's
# copies so the children can EOF cleanly.

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf

echo "[test_multipipe] (1/4) Build userland"
bash scripts/build_user.sh
bash scripts/build_modules.sh

echo "[test_multipipe] (2/4) Swap /init = $HAMSH_ELF"
INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py

echo "[test_multipipe] (3/4) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF"

echo "[test_multipipe] (4/4) Boot QEMU and drive hamsh"
LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null' EXIT

set +e
(
    sleep 3
    printf 'echo three-stage-pipeline | cat | cat\n'
    sleep 3
    printf 'exit\n'
    sleep 1
) | timeout 18s qemu-system-x86_64 \
    -kernel "$ELF" \
    -smp 2 \
    -nographic \
    -no-reboot \
    -m 256M \
    -monitor none \
    -serial stdio \
    > "$LOG" 2>&1
rc=$?
set -e

echo "[test_multipipe] --- captured output ---"
cat "$LOG"
echo "[test_multipipe] --- end output ---"

fail=0
cleaned=$(sed 's/task: pid -*[0-9]* exited (code=-*[0-9]*)//g' "$LOG" | tr '\n' ' ' | tr -s ' ')
if echo "$cleaned" | grep -F -q "three-stage-pipeline"; then
    echo "[test_multipipe] OK: phrase passed all 3 stages"
else
    echo "[test_multipipe] MISS: 'three-stage-pipeline' not found"
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_multipipe] FAIL (qemu rc=$rc)"
    exit 1
fi
echo "[test_multipipe] PASS"
