#!/usr/bin/env bash
# scripts/test_9p_socketpair_e2e.sh — V5 9P-over-socketpair loop.
#
# Same end-to-end shape as scripts/test_9p_e2e.sh but uses ONE
# sys_socketpair() for the transport instead of two unidirectional
# sys_pipe() calls + the "p9rx:<fd>:" magic prefix.
#
# Pipeline:
#   1. Build userland (hamsh + coreutils + p9srv_demo).
#   2. Build tests/test_9p_socketpair_e2e.ad -> build/user/test_9p_socketpair_e2e.elf.
#   3. Plant /init = hamsh.elf.
#   4. Rebuild the kernel image (picks up the socketpair surface).
#   5. Boot in QEMU, drive `/bin/test_9p_socketpair_e2e` via the serial stdio,
#      then `exit`.
#   6. Grep the serial log for the [p9spair] markers + PASS.

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-vmlinux.elf
HAMSH_ELF=build/user/hamsh.elf
TEST_ELF=build/user/test_9p_socketpair_e2e.elf

echo "[test_9p_socketpair_e2e] (1/5) Build userland"
bash scripts/build_user.sh >/dev/null
bash scripts/build_modules.sh >/dev/null

echo "[test_9p_socketpair_e2e] (2/5) Build tests/test_9p_socketpair_e2e.ad -> $TEST_ELF"
mkdir -p build/user
python3 -m compiler.adder compile \
    --target=x86_64-adder-user \
    tests/test_9p_socketpair_e2e.ad \
    -o "$TEST_ELF" >/dev/null

echo "[test_9p_socketpair_e2e] (3/5) Plant /init = hamsh + /bin/test_9p_socketpair_e2e"
INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py >/dev/null

echo "[test_9p_socketpair_e2e] (4/5) Rebuild kernel image"
mkdir -p build
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

echo "[test_9p_socketpair_e2e] (5/5) Boot QEMU + drive the test via hamsh"
LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null' EXIT

set +e
(
    sleep 3
    printf '/bin/test_9p_socketpair_e2e\n'
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

echo "[test_9p_socketpair_e2e] --- captured output ---"
cat "$LOG"
echo "[test_9p_socketpair_e2e] --- end output ---"

fail=0

check_marker() {
    local marker="$1"
    local label="$2"
    if grep -F -q "$marker" "$LOG"; then
        echo "[test_9p_socketpair_e2e] OK: $label"
    else
        echo "[test_9p_socketpair_e2e] MISS: $label ($marker)"
        fail=1
    fi
}

check_marker "[p9spair] start"        "fixture ran"
check_marker "[p9spair] pair OK"      "sys_socketpair allocated"
check_marker "[p9spair] spawn OK"     "/bin/p9srv_demo spawned"
check_marker "[p9spair] mount OK"     "sys_mount over socketpair (no p9rx)"
check_marker "[p9spair] open OK"      "sys_open routed through 9P client"
check_marker "[p9spair] payload OK"   "Rread carried 'p9demo says hi\\n'"
check_marker "[p9spair] close OK"     "sys_close issued Tclunk"
check_marker "[p9spair] PASS"         "fixture reached PASS"

if [ "$fail" -ne 0 ]; then
    echo "[test_9p_socketpair_e2e] FAIL (qemu rc=$rc)"
    exit 1
fi

echo "[test_9p_socketpair_e2e] PASS"
