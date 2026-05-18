#!/usr/bin/env bash
# scripts/test_srv_post.sh - Phase D / V4 regression for the
# sys_srv_post (275) / sys_srv_open (276) syscall pair.
#
# Pipeline:
#   1. Build userland (hamsh + coreutils + init).
#   2. Build the fixture tests/test_srv_post.ad to
#      build/user/test_srv_post.elf (lands at /bin/test_srv_post in
#      the cpio via build_initramfs.py's auto-glob).
#   3. /init = hamsh.elf so we land at a shell prompt without going
#      through the recipe-applying init (which is irrelevant here —
#      we test direct syscalls, not the bind-rewritten path).
#   4. Rebuild the kernel image so the new SYS_SRV_POST /
#      SYS_SRV_OPEN dispatch arms are compiled in.
#   5. Boot in QEMU, drive `/bin/test_srv_post` over the serial
#      stdio, then `exit`.
#   6. Grep the serial log for the fixture's markers + PASS.
#
# Markers asserted (from tests/test_srv_post.ad):
#   [srv_post] start
#   [srv_post] posted
#   [srv_post] child_open OK
#   [srv_post] child_wrote OK
#   [srv_post] parent_read OK
#   [srv_post] PASS

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-vmlinux.elf
HAMSH_ELF=build/user/hamsh.elf
TEST_ELF=build/user/test_srv_post.elf

echo "[test_srv_post] (1/5) Build userland (hamsh + coreutils)"
bash scripts/build_user.sh >/dev/null
bash scripts/build_modules.sh >/dev/null

echo "[test_srv_post] (2/5) Build tests/test_srv_post.ad -> $TEST_ELF"
python3 -m compiler.adder compile \
    --target=x86_64-adder-user \
    tests/test_srv_post.ad \
    -o "$TEST_ELF" >/dev/null

echo "[test_srv_post] (3/5) Plant /init = hamsh + /bin/test_srv_post in cpio"
INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py >/dev/null

echo "[test_srv_post] (4/5) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

echo "[test_srv_post] (5/5) Boot QEMU + drive the test via hamsh"
LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null' EXIT

set +e
(
    sleep 3
    printf '/bin/test_srv_post\n'
    sleep 3
    printf 'exit\n'
    sleep 1
) | timeout 25s qemu-system-x86_64 \
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

echo "[test_srv_post] --- captured output ---"
cat "$LOG"
echo "[test_srv_post] --- end output ---"

fail=0

check_marker() {
    local marker="$1"
    local label="$2"
    if grep -F -q "$marker" "$LOG"; then
        echo "[test_srv_post] OK: $label"
    else
        echo "[test_srv_post] MISS: $label ($marker)"
        fail=1
    fi
}

check_marker "[srv_post] start"          "fixture ran"
check_marker "[srv_post] posted"         "sys_srv_post returned 0"
check_marker "[srv_post] child_open OK"  "child's sys_srv_open returned a fd"
check_marker "[srv_post] child_wrote OK" "child wrote through dup'd fd"
check_marker "[srv_post] parent_read OK" "parent read both sentinels"
check_marker "[srv_post] PASS"           "fixture reached PASS"

if [ "$fail" -ne 0 ]; then
    echo "[test_srv_post] FAIL (qemu rc=$rc)"
    exit 1
fi

echo "[test_srv_post] PASS"
