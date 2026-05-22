#!/usr/bin/env bash
# scripts/test_hamsh_nsscope.sh — HAMSH_SPEC §18 stage 6 acceptance.
#
# `ns { }` scope + overlay default (§10, §13):
#   * A bind done INSIDE an `ns { }` block is GONE after the closing
#     brace — the scope dissolves.
#   * Nested `ns { ns { } }` inherits the outer view then narrows.
#   * Default `ns { }` OVERLAYS — it starts from a COW copy of the
#     ambient namespace, so the ambient binds (here `/fd`, the device
#     binds) survive INSIDE the block.
#   * `ns clean { }` is HERMETIC — an empty base; the ambient binds
#     are absent unless the block re-binds them itself.
#
# Model: `ns { }` desugars to rfork(RFPROC|RFNAMEG) — a child whose
# Pgrp is a COW clone; the child runs the body, the parent waits, the
# child's binds evaporate when it exits. `ns clean` uses RFCNAMEG —
# a fresh EMPTY Pgrp.

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
    # An ambient bind at the prompt — it must survive into a default
    # `ns { }` overlay but be absent from a `ns clean { }` base.
    printf 'bind /ambient_mark /tmp\n'
    sleep 1
    # Inside a default ns {}: bind something, dump the namespace.
    printf 'echo NS_INSIDE\n'
    sleep 1
    printf 'ns {\nbind /scoped_mark /tmp\ncat /proc/self/ns\n}\n'
    sleep 3
    # After the brace: the scoped bind is gone; the ambient bind stays.
    printf 'echo NS_AFTER\n'
    sleep 1
    printf 'cat /proc/self/ns\n'
    sleep 2
    # `ns clean {}` — hermetic: the ambient bind must be ABSENT.
    printf 'echo NS_CLEAN\n'
    sleep 1
    printf 'ns clean {\ncat /proc/self/ns\n}\n'
    sleep 3
    # Nested ns { ns { } } — the inner scope inherits then narrows.
    printf 'echo NS_NESTED\n'
    sleep 1
    printf 'ns {\nbind /outer_mark /tmp\nns {\nbind /inner_mark /tmp\ncat /proc/self/ns\n}\n}\n'
    sleep 4
    printf 'echo NS_DONE\n'
    sleep 1
    printf 'exit\n'
    sleep 1
) | timeout 70s qemu-system-x86_64 \
    -kernel "$ELF" -smp 2 -nographic -no-reboot -m 256M \
    -monitor none -serial stdio > "$LOG" 2>&1
set -e

echo "[test_hamsh_nsscope] --- captured ---"
cat "$LOG"
echo "[test_hamsh_nsscope] --- end ---"

fail=0

inside_block=$(sed -n '/NS_INSIDE/,/NS_AFTER/p' "$LOG")
after_block=$(sed -n '/NS_AFTER/,/NS_CLEAN/p' "$LOG")
clean_block=$(sed -n '/NS_CLEAN/,/NS_NESTED/p' "$LOG")
nested_block=$(sed -n '/NS_NESTED/,/NS_DONE/p' "$LOG")

# Inside the default ns {}: the scoped bind is visible.
if echo "$inside_block" | grep -F -q "/scoped_mark"; then
    echo "[test_hamsh_nsscope] OK: bind inside ns {} is visible inside the block"
else
    echo "[test_hamsh_nsscope] MISS: bind inside ns {} not visible"
    fail=1
fi

# Inside the default ns {}: the ambient bind survived the overlay.
if echo "$inside_block" | grep -F -q "/ambient_mark"; then
    echo "[test_hamsh_nsscope] OK: default ns {} overlays — ambient bind survives"
else
    echo "[test_hamsh_nsscope] MISS: default ns {} lost the ambient bind"
    fail=1
fi

# After the brace: the scoped bind is GONE.
if echo "$after_block" | grep -F -q "/scoped_mark"; then
    echo "[test_hamsh_nsscope] FAIL: bind inside ns {} leaked past the brace"
    fail=1
else
    echo "[test_hamsh_nsscope] OK: bind inside ns {} is gone after the brace"
fi

# After the brace: the ambient bind still there (scope only narrowed).
if echo "$after_block" | grep -F -q "/ambient_mark"; then
    echo "[test_hamsh_nsscope] OK: ambient bind survives the ns {} teardown"
else
    echo "[test_hamsh_nsscope] MISS: ambient bind lost after ns {}"
    fail=1
fi

# `ns clean {}` is hermetic: the ambient bind must be ABSENT.
if echo "$clean_block" | grep -F -q "/ambient_mark"; then
    echo "[test_hamsh_nsscope] FAIL: ns clean {} leaked the ambient bind (not hermetic)"
    fail=1
else
    echo "[test_hamsh_nsscope] OK: ns clean {} is hermetic — ambient bind absent"
fi

# Nested ns { ns {} }: the inner scope sees BOTH the outer bind
# (inherited) and its own (narrowed).
if echo "$nested_block" | grep -F -q "/outer_mark" \
        && echo "$nested_block" | grep -F -q "/inner_mark"; then
    echo "[test_hamsh_nsscope] OK: nested ns {} inherits the outer scope then narrows"
else
    echo "[test_hamsh_nsscope] MISS: nested ns {} did not inherit+narrow"
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_hamsh_nsscope] FAIL"
    exit 1
fi
echo "[test_hamsh_nsscope] PASS"
