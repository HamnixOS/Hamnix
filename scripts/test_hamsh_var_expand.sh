#!/usr/bin/env bash
# scripts/test_hamsh_var_expand.sh — M16.x in-token `$VAR` / `$?` expansion.
#
# Pre-existing hamsh accepted `echo $FOO` (whole-token starts with `$`)
# but left `X=$Y`, `prefix-$ID`, and `before=$? after` literal. This
# test exercises the per-character expansion pass added to
# user/hamsh.ad's process_line:
#
#   echo before=$? after_exit_code   →  before=0 after_exit_code
#   X=hello                          → (assignment, no echo)
#   echo prefix=$X-suffix            →  prefix=hello-suffix
#   echo $X$X                        →  hellohello
#
# PASS marker: `[hamsh_var_expand] PASS`.
#
# Boot uses the same shape as the other test_hamsh_*.sh fixtures:
# plant hamsh.elf as /init, rebuild the kernel image, drive QEMU
# over -serial stdio with sleeps between writes to keep the 16550
# RX FIFO happy.

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-vmlinux.elf
HAMSH_ELF=build/user/hamsh.elf

echo "[test_hamsh_var_expand] (1/3) Build userland"
bash scripts/build_user.sh >/dev/null

echo "[test_hamsh_var_expand] (2/3) Plant /init = hamsh in initramfs"
INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py >/dev/null

echo "[test_hamsh_var_expand] (3/3) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal init/main.ad -o "$ELF" >/dev/null

LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null' EXIT

set +e
(
    sleep 4
    # `before=$?` exercises in-token `$?`. Initial last_exit_code
    # is 0 so we expect `before=0 after_exit_code`.
    printf 'echo before=$? after_exit_code\n'
    sleep 1
    # Assign and reference via prefix/suffix wrap.
    printf 'X=hello\n'
    sleep 1
    printf 'echo prefix=$X-suffix\n'
    sleep 1
    # Two adjacent `$X` references in a single token — exercises
    # the post-NAME continue path of the expansion walker.
    printf 'echo $X$X\n'
    sleep 1
    printf 'exit\n'
    sleep 1
) | timeout 22s qemu-system-x86_64 \
    -kernel "$ELF" \
    -smp 2 -nographic -no-reboot -m 256M -monitor none -serial stdio \
    > "$LOG" 2>&1
set -e

echo "[test_hamsh_var_expand] --- captured ---"
cat "$LOG"
echo "[test_hamsh_var_expand] --- end ---"

fail=0

if grep -F -q "before=0 after_exit_code" "$LOG"; then
    echo "[test_hamsh_var_expand] OK: in-token \$? expanded"
else
    echo "[test_hamsh_var_expand] MISS: 'before=0 after_exit_code'"
    fail=1
fi

if grep -F -q "prefix=hello-suffix" "$LOG"; then
    echo "[test_hamsh_var_expand] OK: prefix/suffix in-token \$X"
else
    echo "[test_hamsh_var_expand] MISS: 'prefix=hello-suffix'"
    fail=1
fi

if grep -F -q "hellohello" "$LOG"; then
    echo "[test_hamsh_var_expand] OK: adjacent \$X\$X expanded"
else
    echo "[test_hamsh_var_expand] MISS: 'hellohello'"
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_hamsh_var_expand] FAIL"
    exit 1
fi
echo "[test_hamsh_var_expand] PASS"
