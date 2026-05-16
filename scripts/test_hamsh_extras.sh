#!/usr/bin/env bash
# scripts/test_hamsh_extras.sh — M16.69 verification.
#
# Tests hamsh additions:
#   * `#` lines are ignored as comments
#   * `$?` expands to the last command's exit code
#
# The boot session runs:
#   1. true            → exit 0
#   2. echo $?         → should print "0"
#   3. false           → exit 1
#   4. echo $?         → should print "1"
#   5. # comment line   → silently ignored, no error
#   6. echo POST_COMMENT_OK

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
    printf 'true\n'
    sleep 1
    # echo TRUE_RC $?  →  hamsh substitutes the $? token to the
    # decimal of last_exit_code (0 after /true). The space-separated
    # form keeps M16.69's standalone-token substitution sufficient;
    # in-token substitution ("TRUE_RC=$?") is left for a later
    # M16.7x once we add a per-token expansion buffer.
    printf 'echo TRUE_RC $?\n'
    sleep 1
    printf 'false\n'
    sleep 1
    printf 'echo FALSE_RC $?\n'
    sleep 1
    printf '# this is a comment, should be ignored\n'
    sleep 1
    printf 'echo POST_COMMENT_OK\n'
    sleep 1
    printf 'exit\n'
    sleep 1
) | timeout 18s qemu-system-x86_64 \
    -kernel "$ELF" \
    -smp 2 -nographic -no-reboot -m 256M -monitor none -serial stdio \
    > "$LOG" 2>&1
set -e

fail=0
if grep -F -q "TRUE_RC 0" "$LOG"; then
    echo "[test_hamsh_extras] OK: \$? after true is 0"
else
    echo "[test_hamsh_extras] MISS: \$? after true not 0"
    fail=1
fi
if grep -F -q "FALSE_RC 1" "$LOG"; then
    echo "[test_hamsh_extras] OK: \$? after false is 1"
else
    echo "[test_hamsh_extras] MISS: \$? after false not 1"
    fail=1
fi
if grep -F -q "POST_COMMENT_OK" "$LOG"; then
    echo "[test_hamsh_extras] OK: # comment line skipped cleanly"
else
    echo "[test_hamsh_extras] MISS: shell died on '#' comment"
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_hamsh_extras] --- captured ---"
    cat "$LOG"
    echo "[test_hamsh_extras] --- end ---"
    echo "[test_hamsh_extras] FAIL"
    exit 1
fi
echo "[test_hamsh_extras] PASS"
