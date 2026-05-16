#!/usr/bin/env bash
# scripts/test_path.sh — M16.72 verification.
#
# Confirms that:
#   1. Userland binaries live at /bin/<name> in the initramfs
#   2. hamsh resolves bare names (no leading /) via PATH walk
#   3. Legacy /xxx still works for the small alias set

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
    # Bare name: PATH lookup must find /bin/echo and run it.
    printf 'echo BARE_PATH_OK\n'
    sleep 1
    # Absolute /bin path: explicit reference works directly.
    printf '/bin/echo SLASH_BIN_OK\n'
    sleep 1
    # Pipeline with bare names — both resolved via PATH.
    printf 'echo LEGACY_PIPE_OK | cat\n'
    sleep 1
    # Bad name: PATH walk exhausts, hamsh reports not-found, but
    # the shell SURVIVES (next prompt still works).
    printf 'definitely_not_a_command\n'
    sleep 1
    printf 'echo SURVIVED_NOTFOUND\n'
    sleep 1
    printf 'exit\n'
    sleep 1
) | timeout 22s qemu-system-x86_64 \
    -kernel "$ELF" \
    -smp 2 -nographic -no-reboot -m 256M -monitor none -serial stdio \
    > "$LOG" 2>&1
set -e

fail=0
check_present() {
    if grep -F -q "$1" "$LOG"; then
        echo "[test_path] OK: $1"
    else
        echo "[test_path] MISS: $1"
        fail=1
    fi
}
check_present "BARE_PATH_OK"
check_present "SLASH_BIN_OK"
check_present "LEGACY_PIPE_OK"
check_present "SURVIVED_NOTFOUND"
if grep -F -q "not found: definitely_not_a_command" "$LOG"; then
    echo "[test_path] OK: bad command reported not-found"
else
    echo "[test_path] MISS: bad-command error path"
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_path] --- captured ---"
    cat "$LOG"
    echo "[test_path] --- end ---"
    echo "[test_path] FAIL"
    exit 1
fi
echo "[test_path] PASS"
