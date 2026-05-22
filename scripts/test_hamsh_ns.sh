#!/usr/bin/env bash
# scripts/test_hamsh_ns.sh — HAMSH_SPEC §18 stage 5 acceptance.
#
# Ambient namespace + COW-for-externals (§9):
#   * A composition-verb BUILTIN (`bind`) runs in-process and mutates
#     the shell's AMBIENT namespace — it persists, shows up in
#     `cat /proc/self/ns`, and a subsequent command sees it.
#   * An EXTERNAL command gets a copy-on-write PRIVATE copy of the
#     ambient namespace — its `bind` evaporates on exit and NEVER
#     appears in the shell's /proc/self/ns. A command can never
#     corrupt the prompt's view.
#
# The model: the prompt IS the outermost namespace; a bare external
# command runs in a COW clone of it (sys_spawn's SPAWN_STDIO_NS path
# clones the shell's Pgrp); composition verbs are builtins that mutate
# the shell's Pgrp directly.

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
    # A builtin bind at the prompt — mutates the AMBIENT namespace.
    printf 'bind /nsbuiltin /tmp\n'
    sleep 1
    # The shell's own /proc/self/ns must now carry that binding.
    printf 'echo NS_AMBIENT_VIEW\n'
    sleep 1
    printf 'cat /proc/self/ns\n'
    sleep 2
    # An EXTERNAL command does its own bind in a COW-private namespace.
    printf '/bin/nsbindprobe\n'
    sleep 2
    # The shell's /proc/self/ns must NOT carry the external's bind.
    printf 'echo NS_AFTER_EXTERNAL\n'
    sleep 1
    printf 'cat /proc/self/ns\n'
    sleep 2
    printf 'echo NS_DONE\n'
    sleep 1
    printf 'exit\n'
    sleep 1
) | timeout 55s qemu-system-x86_64 \
    -kernel "$ELF" -smp 2 -nographic -no-reboot -m 256M \
    -monitor none -serial stdio > "$LOG" 2>&1
set -e

echo "[test_hamsh_ns] --- captured ---"
cat "$LOG"
echo "[test_hamsh_ns] --- end ---"

fail=0

# The builtin bind ran and the external probe ran at all.
if grep -F -q "NSBINDPROBE bind done" "$LOG"; then
    echo "[test_hamsh_ns] OK: external command performed its own bind"
else
    echo "[test_hamsh_ns] MISS: external bind probe did not run"
    fail=1
fi

# The first /proc/self/ns dump (after the builtin bind) must show it;
# the dump after the external must STILL show it (builtin persists)
# but must NOT show the external's /extbind_probe.
ambient_block=$(sed -n '/NS_AMBIENT_VIEW/,/NS_AFTER_EXTERNAL/p' "$LOG")
after_block=$(sed -n '/NS_AFTER_EXTERNAL/,/NS_DONE/p' "$LOG")

if echo "$ambient_block" | grep -F -q "/nsbuiltin"; then
    echo "[test_hamsh_ns] OK: builtin bind appears in shell /proc/self/ns"
else
    echo "[test_hamsh_ns] MISS: builtin bind absent from /proc/self/ns"
    fail=1
fi

if echo "$after_block" | grep -F -q "/nsbuiltin"; then
    echo "[test_hamsh_ns] OK: builtin bind persists for later commands"
else
    echo "[test_hamsh_ns] MISS: builtin bind did not persist"
    fail=1
fi

if echo "$after_block" | grep -F -q "/extbind_probe"; then
    echo "[test_hamsh_ns] FAIL: external command's bind leaked into the shell ns"
    fail=1
else
    echo "[test_hamsh_ns] OK: external command's bind did NOT leak (COW private ns)"
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_hamsh_ns] FAIL"
    exit 1
fi
echo "[test_hamsh_ns] PASS"
