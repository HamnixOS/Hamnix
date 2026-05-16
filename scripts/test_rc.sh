#!/usr/bin/env bash
# scripts/test_rc.sh — M16.73 verification.
#
# /etc/rc is auto-sourced by hamsh at startup. The shipped /etc/rc
# runs `motd`, which prints /etc/motd. So booting fresh should land
# us at a prompt with the motd text visible in the captured stream.

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
    sleep 4
    printf 'echo POST_RC_OK\n'
    sleep 1
    printf 'exit\n'
    sleep 1
) | timeout 12s qemu-system-x86_64 \
    -kernel "$ELF" \
    -smp 2 -nographic -no-reboot -m 256M -monitor none -serial stdio \
    > "$LOG" 2>&1
set -e

fail=0
# /etc/motd's first line — verifies motd ran via /etc/rc.
if grep -F -q "Welcome to Hamnix" "$LOG"; then
    echo "[test_rc] OK: /etc/rc sourced motd at startup"
else
    echo "[test_rc] MISS: motd output not seen"
    fail=1
fi
if grep -F -q "POST_RC_OK" "$LOG"; then
    echo "[test_rc] OK: interactive prompt available after /etc/rc"
else
    echo "[test_rc] MISS: shell didn't reach interactive after /etc/rc"
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_rc] --- captured ---"
    cat "$LOG"
    echo "[test_rc] --- end ---"
    echo "[test_rc] FAIL"
    exit 1
fi
echo "[test_rc] PASS"
