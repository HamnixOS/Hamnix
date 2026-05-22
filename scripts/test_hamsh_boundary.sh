#!/usr/bin/env bash
# scripts/test_hamsh_boundary.sh — HAMSH_SPEC §18 stage 8 acceptance.
#
# Boundary scoping (§13) — what crosses a namespace boundary:
#   * DATA crosses. `x = "hi"; enter s { echo $x }` prints `hi` — the
#     value was copied into the child at the fork.
#   * Writes do NOT cross back. A variable set inside `enter` is unset
#     in the shell afterward (the subshell rule).
#   * A LIVE HANDLE is namespace-local. A process handle created in
#     the ambient namespace, used inside `enter s { }`, raises the
#     cross-namespace-handle error — loud, not undefined.
#   * `enter clean` is hermetic — the ambient binds are absent; the
#     default `enter` overlay keeps them.
#
# The governing rule: values cross the boundary; resolution is
# namespace-local.

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
    printf 'sandbox = ns {\nbind /sbx /tmp\n}\n'
    sleep 2
    # DATA crosses: $x is copied into the enter child at fork.
    printf 'x = "hi_value"\n'
    sleep 1
    printf 'enter sandbox {\necho DATA_CROSS $x\n}\n'
    sleep 3
    # Writes do NOT cross back: set a var inside enter, check outside.
    printf 'y = "before"\n'
    sleep 1
    printf 'enter sandbox {\ny = "mutated"\n}\n'
    sleep 3
    printf 'echo NOWRITEBACK $y\n'
    sleep 1
    # LIVE HANDLE is namespace-local: a process handle made in the
    # ambient namespace, used inside enter, is the cross-ns error.
    printf 'svc = spawn sandbox {\nsleep 300\n}\n'
    sleep 2
    printf 'enter sandbox {\nkill $svc\necho HANDLE_ERR $errstr\n}\n'
    sleep 3
    # Clean up the still-running spawned process from the ambient ns
    # (where the handle IS valid).
    printf 'kill $svc\n'
    sleep 2
    # `enter clean` is hermetic vs default overlay (ambient bind /fd).
    printf 'echo CLEANCHECK\n'
    sleep 1
    printf 'enter clean sandbox {\ncat /proc/self/ns\n}\n'
    sleep 3
    printf 'echo DONE\n'
    sleep 1
    printf 'exit\n'
    sleep 1
) | timeout 75s qemu-system-x86_64 \
    -kernel "$ELF" -smp 2 -nographic -no-reboot -m 256M \
    -monitor none -serial stdio > "$LOG" 2>&1
set -e

echo "[test_hamsh_boundary] --- captured ---"
cat "$LOG"
echo "[test_hamsh_boundary] --- end ---"

fail=0

# DATA crosses — $x carried into the enter child.
if grep -F -q "DATA_CROSS hi_value" "$LOG"; then
    echo "[test_hamsh_boundary] OK: data crosses the boundary (fork copy)"
else
    echo "[test_hamsh_boundary] MISS: data did not cross into enter"
    fail=1
fi

# Writes do NOT cross back — $y stays "before".
if grep -F -q "NOWRITEBACK before" "$LOG"; then
    echo "[test_hamsh_boundary] OK: variable set inside enter does not write back"
elif grep -F -q "NOWRITEBACK mutated" "$LOG"; then
    echo "[test_hamsh_boundary] FAIL: write inside enter leaked back to the shell"
    fail=1
else
    echo "[test_hamsh_boundary] MISS: write-back check produced no output"
    fail=1
fi

# A live handle used across the boundary raises the error.
if grep -F -q "HANDLE_ERR handle used outside its owning namespace" "$LOG"; then
    echo "[test_hamsh_boundary] OK: cross-namespace handle use raises the error"
else
    echo "[test_hamsh_boundary] MISS: cross-namespace handle use not flagged"
    fail=1
fi

# `enter clean` is hermetic — the ambient /fd bind must be absent.
clean_block=$(sed -n '/CLEANCHECK/,/DONE/p' "$LOG")
if echo "$clean_block" | grep -F -q "bind /sbx"; then
    echo "[test_hamsh_boundary] OK: enter clean applies the template (own binds)"
else
    echo "[test_hamsh_boundary] MISS: enter clean did not apply the template"
    fail=1
fi
if echo "$clean_block" | grep -F -q "/ambient_never_bound"; then
    echo "[test_hamsh_boundary] FAIL: enter clean leaked an ambient bind"
    fail=1
else
    echo "[test_hamsh_boundary] OK: enter clean is hermetic"
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_hamsh_boundary] FAIL"
    exit 1
fi
echo "[test_hamsh_boundary] PASS"
