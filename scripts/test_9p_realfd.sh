#!/usr/bin/env bash
# scripts/test_9p_realfd.sh — V4.1 real-fd 9P create/write/read loop.
#
# Where scripts/test_9p_e2e.sh proved walk + open + READ over a real
# fd, THIS test closes the WRITE leg of the keystone: the kernel 9P
# client mounts the userland `distrofs` daemon over a real fd and
# drives a full walk -> open -> CREATE -> WRITE -> read round-trip.
#
# Every wire byte goes through the real `_p9_send` / `_p9_recv` pipe
# path in sys/src/9/port/9p_client.ad (p9c_create / p9c_walk_create_path
# are the new surface) rather than the V1 smoke responder.
#
# Pipeline (same shape as scripts/test_9p_e2e.sh):
#   1. Build userland (hamsh + coreutils + distrofs).
#   2. Build the fixture tests/test_9p_realfd.ad -> build/user/test_9p_realfd.elf.
#   3. Plant /init = hamsh.elf.
#   4. Rebuild the kernel image (picks up the 9p_client.ad + vfs.ad changes).
#   5. Boot in QEMU, drive `/bin/test_9p_realfd` via the serial stdio, exit.
#   6. Grep the serial log for the [p9_realfd] markers + PASS.

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf
TEST_ELF=build/user/test_9p_realfd.elf

echo "[test_9p_realfd] (1/5) Build userland (hamsh + coreutils + distrofs)"
bash scripts/build_user.sh >/dev/null
bash scripts/build_modules.sh >/dev/null

echo "[test_9p_realfd] (2/5) Build tests/test_9p_realfd.ad -> $TEST_ELF"
mkdir -p build/user
python3 -m compiler.adder compile \
    --target=x86_64-adder-user \
    tests/test_9p_realfd.ad \
    -o "$TEST_ELF" >/dev/null

echo "[test_9p_realfd] (3/5) Plant /init = hamsh + /bin/test_9p_realfd in cpio"
INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py >/dev/null

echo "[test_9p_realfd] (4/5) Rebuild kernel image"
mkdir -p build
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

echo "[test_9p_realfd] (5/5) Boot QEMU + drive the test via hamsh"
LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null' EXIT

set +e
(
    sleep 3
    printf '/bin/test_9p_realfd\n'
    sleep 5
    printf 'exit\n'
    sleep 1
) | timeout 30s qemu-system-x86_64 \
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

echo "[test_9p_realfd] --- captured output ---"
cat "$LOG"
echo "[test_9p_realfd] --- end output ---"

fail=0

check_marker() {
    local marker="$1"
    local label="$2"
    if grep -F -q "$marker" "$LOG"; then
        echo "[test_9p_realfd] OK: $label"
    else
        echo "[test_9p_realfd] MISS: $label ($marker)"
        fail=1
    fi
}

# Any per-assertion FAIL line means the round-trip broke somewhere.
if grep -F -q "[p9_realfd] FAIL:" "$LOG"; then
    echo "[test_9p_realfd] MISS: per-assertion FAIL line(s) present:"
    grep -F "[p9_realfd] FAIL:" "$LOG" | sed 's/^/  /'
    fail=1
else
    echo "[test_9p_realfd] OK: no per-assertion FAIL lines"
fi

check_marker "[p9_realfd] start"     "fixture ran"
check_marker "[p9_realfd] pipes OK"  "sys_pipe pair allocated"
check_marker "[p9_realfd] spawn OK"  "/bin/distrofs spawned"
check_marker "[p9_realfd] srv_post OK" "sys_srv_post"
check_marker "[p9_realfd] srv_open OK" "sys_srv_open"
check_marker "[p9_realfd] mount OK"  "sys_mount completed Tversion+Tattach"
check_marker "[p9_realfd] create OK" "create-on-write-open issued Tcreate"
check_marker "[p9_realfd] write OK"  "sys_write issued Twrite"
check_marker "[p9_realfd] reopen OK" "re-open of the created file walked+opened"
check_marker "[p9_realfd] payload OK" "Tread round-trip returned the written bytes"
check_marker "[p9_realfd] PASS"      "fixture reached PASS"

if [ "$fail" -ne 0 ]; then
    echo "[test_9p_realfd] FAIL (qemu rc=$rc)"
    exit 1
fi

echo "[test_9p_realfd] PASS"
