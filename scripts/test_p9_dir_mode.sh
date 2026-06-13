#!/usr/bin/env bash
# scripts/test_p9_dir_mode.sh - F10-6 followup acceptance gate.
# Verifies per-Chan p9_dir_mode flip + Dir-record read path end-to-end.

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf
TEST_ELF=build/user/test_p9_dir_mode.elf

echo "[test_p9_dir_mode] (1/5) Build userland (hamsh + coreutils)"
bash scripts/build_user.sh >/dev/null
bash scripts/build_modules.sh >/dev/null

echo "[test_p9_dir_mode] (2/5) Build tests/test_p9_dir_mode.ad -> $TEST_ELF"
python3 -m compiler.adder compile \
    --target=x86_64-adder-user \
    tests/test_p9_dir_mode.ad \
    -o "$TEST_ELF" >/dev/null

echo "[test_p9_dir_mode] (3/5) Plant /init = hamsh + /bin/test_p9_dir_mode in cpio"
INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py >/dev/null

echo "[test_p9_dir_mode] (4/5) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

echo "[test_p9_dir_mode] (5/5) Boot QEMU + drive the test via hamsh"
LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null' EXIT

set +e
(
    sleep 3
    for _i in 1 2 3 4; do
        printf '/bin/test_p9_dir_mode\n'
        sleep 2
    done
    printf 'exit\n'
    sleep 1
) | timeout 35s qemu-system-x86_64 \
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

echo "[test_p9_dir_mode] --- captured output ---"
cat "$LOG"
echo "[test_p9_dir_mode] --- end output ---"

fail=0

check_marker() {
    local marker="$1"
    local label="$2"
    if grep -F -q "$marker" "$LOG"; then
        echo "[test_p9_dir_mode] OK: $label"
    else
        echo "[test_p9_dir_mode] MISS: $label ($marker)"
        fail=1
    fi
}

check_marker "[p9dm] start"            "fixture ran"
check_marker "[p9dm] posted"           "srv_post returned 0"
check_marker "[p9dm] line stream OK"   "legacy NAME\\n path still works"
check_marker "[p9dm] dir mode flip OK" "SYS_CHAN_DIR_MODE returned 0"
check_marker "[p9dm] record decoded"   "p9_dir_decode_at consumed >=1 record"
check_marker "[p9dm] name match OK"    "Dir record carried posted name"
check_marker "[p9dm] PASS"             "fixture reached PASS"

if [ "$fail" -ne 0 ]; then
    echo "[test_p9_dir_mode] FAIL (qemu rc=$rc)"
    exit 1
fi

echo "[test_p9_dir_mode] PASS"
