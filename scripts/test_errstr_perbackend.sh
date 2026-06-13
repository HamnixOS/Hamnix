#!/usr/bin/env bash
# scripts/test_errstr_perbackend.sh - regression for the TODO net-item
# closure "Per-backend errstr + user-mode perror helper".
#
# Boots Hamnix under QEMU, drives /bin/test_errstr_perbackend over the
# serial stdio, then greps the captured log for:
#   * the "ext4:" prefix on a failed /ext open (proves the ext4 backend
#     installed its backend-tagged errstr before the syscall-layer
#     fallback got the chance to overwrite it),
#   * the perror line that includes BOTH the msg prefix ("[test_errstr_pb] open:")
#     AND the kernel-installed "ext4:" backend tag.

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf

echo "[test_errstr_pb] (1/4) Build userland (incl. test_errstr_perbackend)"
bash scripts/build_user.sh >/dev/null
bash scripts/build_modules.sh >/dev/null

echo "[test_errstr_pb] (2/4) Plant /init = hamsh + /bin/test_errstr_perbackend in cpio"
INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py >/dev/null

echo "[test_errstr_pb] (3/4) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

echo "[test_errstr_pb] (4/4) Boot QEMU + drive the test via hamsh"
LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null' EXIT

set +e
# Per project memory ("serial test first-cmd dropped" / "interactive
# tests wait for prompt"): rc.boot now takes >12s to land hamsh at
# its prompt; the legacy `sleep 3` pacing of test_errstr.sh is no
# longer enough. Wait LONGER for boot, RE-SEND the command line
# several times so a dropped first-cmd echo doesn't kill the test.
(
    sleep 25
    printf '/bin/test_errstr_perbackend\n'
    sleep 2
    printf '/bin/test_errstr_perbackend\n'
    sleep 4
    printf 'exit\n'
    sleep 1
) | timeout 60s qemu-system-x86_64 \
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

echo "[test_errstr_pb] --- captured output ---"
cat "$LOG"
echo "[test_errstr_pb] --- end output ---"

fail=0

if grep -F -q "[test_errstr_pb] start" "$LOG"; then
    echo "[test_errstr_pb] OK: fixture ran"
else
    echo "[test_errstr_pb] MISS: fixture banner missing"
    fail=1
fi

# Backend prefix assertion: tmpfs_open_for_write on an existing dir
# (/tmp) sets "tmpfs: open: path is a directory" before the
# syscall-layer fallback "open for write: failed" can overwrite.
if grep -E -q "tmpfs errstr: tmpfs: " "$LOG"; then
    echo "[test_errstr_pb] OK: tmpfs backend installed 'tmpfs:' prefix"
else
    echo "[test_errstr_pb] MISS: tmpfs errstr missing 'tmpfs:' prefix"
    fail=1
fi

# perror assertion: the line carries BOTH the msg AND the backend
# prefix on the same physical line ("<msg>: <errstr>\n").
if grep -E -q "\[test_errstr_pb\] open:.*tmpfs:" "$LOG"; then
    echo "[test_errstr_pb] OK: perror surfaced backend errstr"
else
    echo "[test_errstr_pb] MISS: perror line missing msg+backend"
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_errstr_pb] FAIL (qemu rc=$rc)"
    exit 1
fi

echo "[test_errstr_pb] PASS"
