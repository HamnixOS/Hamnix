#!/usr/bin/env bash
# scripts/test_9p_e2e.sh — V4.1 end-to-end Plan-9 loop.
#
# This is the FIRST test that exercises the full chain:
#
#   userspace fixture
#     -> sys_pipe x2 -> sys_spawn /bin/p9srv_demo
#     -> sys_srv_post + sys_srv_open + sys_mount(spec=p9rx:<rxfd>:)
#     -> sys_open("/n/demo/hello")
#     -> sys_read(h, buf, 32)
#     compare buf == "p9demo says hi\n"
#
# Every wire byte from the kernel side now goes through the real
# `_p9_send` / `_p9_recv` pipe path in sys/src/9/port/9p_client.ad
# rather than the V1 smoke responder.
#
# Pipeline (same shape as scripts/test_p9srv_demo.sh):
#   1. Build userland (hamsh + coreutils + p9srv_demo).
#   2. Build the fixture tests/test_9p_e2e.ad -> build/user/test_9p_e2e.elf.
#   3. Plant /init = hamsh.elf.
#   4. Rebuild the kernel image (picks up the 9p_client.ad changes).
#   5. Boot in QEMU, drive `/bin/test_9p_e2e` via the serial stdio,
#      then `exit`.
#   6. Grep the serial log for the [p9_e2e] markers + PASS.

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf
TEST_ELF=build/user/test_9p_e2e.elf

echo "[test_9p_e2e] (1/5) Build userland (hamsh + coreutils + p9srv_demo)"
bash scripts/build_user.sh >/dev/null
bash scripts/build_modules.sh >/dev/null

echo "[test_9p_e2e] (2/5) Build tests/test_9p_e2e.ad -> $TEST_ELF"
python3 -m compiler.adder compile \
    --target=x86_64-adder-user \
    tests/test_9p_e2e.ad \
    -o "$TEST_ELF" >/dev/null

echo "[test_9p_e2e] (3/5) Plant /init = hamsh + /bin/test_9p_e2e in cpio"
INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py >/dev/null

echo "[test_9p_e2e] (4/5) Rebuild kernel image"
mkdir -p build
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

echo "[test_9p_e2e] (5/5) Boot QEMU + drive the test via hamsh"
LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null' EXIT

set +e
(
    sleep 3
    printf '/bin/test_9p_e2e\n'
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

echo "[test_9p_e2e] --- captured output ---"
cat "$LOG"
echo "[test_9p_e2e] --- end output ---"

fail=0

check_marker() {
    local marker="$1"
    local label="$2"
    if grep -F -q "$marker" "$LOG"; then
        echo "[test_9p_e2e] OK: $label"
    else
        echo "[test_9p_e2e] MISS: $label ($marker)"
        fail=1
    fi
}

check_marker "[p9_e2e] start"      "fixture ran"
check_marker "[p9_e2e] pipes OK"   "sys_pipe pair allocated"
check_marker "[p9_e2e] spawn OK"   "/bin/p9srv_demo spawned"
check_marker "[p9_e2e] srv_post OK" "sys_srv_post"
check_marker "[p9_e2e] srv_open OK" "sys_srv_open"
check_marker "[p9_e2e] mount OK"   "sys_mount completed Tversion+Tattach"
check_marker "[p9_e2e] open OK"    "sys_open routed through kernel 9P client"
check_marker "[p9_e2e] payload OK" "Rread carried 'p9demo says hi\\n'"
check_marker "[p9_e2e] close OK"   "sys_close issued Tclunk"
check_marker "[p9_e2e] PASS"       "fixture reached PASS"

if [ "$fail" -ne 0 ]; then
    echo "[test_9p_e2e] FAIL (qemu rc=$rc)"
    exit 1
fi

echo "[test_9p_e2e] PASS"
