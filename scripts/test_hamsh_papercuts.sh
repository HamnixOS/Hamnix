#!/usr/bin/env bash
# scripts/test_hamsh_papercuts.sh — hamsh interactive-error polish.
#
# Ported to the rewritten shell. The old papercut test bundled two
# fixes; only the first survives into the new shell:
#
#   1. A failing builtin must SHOW its diagnosis at the prompt. `cd`
#      to a missing directory pulls the kernel's errstr (§16) and
#      run_builtin prints `cd: <errstr>` — a bare failing builtin
#      reports cleanly, exactly as a failed external prints
#      "command not found". KEPT and re-verified here.
#
#   2. (DROPPED) The old test also checked arrow-key history line
#      editing. The rewritten shell deliberately has no line editor
#      — it reads raw bytes and relies on paste-robust brace blocks
#      (HAMSH_SPEC §5). A cooked-mode line editor is a feature beyond
#      the spec; that half of the old test is not ported.
#
# Strategy: boot hamsh as /init, drive its serial, and assert the
# failing `cd` surfaces the real kernel error and the shell survives.

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-vmlinux.elf
HAMSH_ELF=build/user/hamsh.elf

echo "[test_hamsh_papercuts] (1/3) Build userland"
bash scripts/build_user.sh >/dev/null

echo "[test_hamsh_papercuts] (2/3) Plant /init = hamsh in initramfs"
INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py >/dev/null

echo "[test_hamsh_papercuts] (3/3) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null' EXIT

set +e
(
    sleep 3
    # cd to a non-existent directory must report the kernel's errstr.
    printf 'cd /nope/nope/nope\n'
    sleep 1
    # Regression — the shell survived the error and runs the next cmd.
    printf 'echo PAPERCUT_SURVIVED\n'
    sleep 1
    printf 'exit\n'
    sleep 1
) | timeout 20s qemu-system-x86_64 \
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

echo "[test_hamsh_papercuts] --- captured output ---"
cat "$LOG"
echo "[test_hamsh_papercuts] --- end output ---"

fail=0

# A failing `cd` surfaces the kernel's errstr, prefixed with "cd: ".
if grep -E -q "cd: .*chdir" "$LOG"; then
    echo "[test_hamsh_papercuts] OK: failing cd surfaces the kernel errstr"
else
    echo "[test_hamsh_papercuts] MISS: cd error message not propagated"
    fail=1
fi

# The shell survived the failed builtin and ran the next command.
if grep -F -q "PAPERCUT_SURVIVED" "$LOG"; then
    echo "[test_hamsh_papercuts] OK: shell survived the failed builtin"
else
    echo "[test_hamsh_papercuts] MISS: shell did not survive the cd error"
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_hamsh_papercuts] FAIL (qemu rc=$rc)"
    exit 1
fi
echo "[test_hamsh_papercuts] PASS"
