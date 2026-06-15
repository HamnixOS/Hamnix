#!/usr/bin/env bash
# scripts/test_dir_record_full.sh — #458 F10-6 (this wave) gate. Boots
# QEMU, runs tests/test_dir_record_full.elf which exercises
# SYS_LISTDIR_RECORDS (318) against /tmp, /dev, and /dev/auth (the
# remaining perm-body-stub backings that were still emitting NAME\n
# lines after the devproc/devnet/devblk wave landed).
#
# Markers asserted (from tests/test_dir_record_full.ad):
#   [dirfull] start
#   [dirfull] tmp OK
#   [dirfull] dev OK
#   [dirfull] auth OK
#   [dirfull] PASS

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf
TEST_ELF=build/user/test_dir_record_full.elf

echo "[test_dir_record_full] (1/5) Build userland"
bash scripts/build_user.sh >/dev/null
bash scripts/build_modules.sh >/dev/null

echo "[test_dir_record_full] (2/5) Build test ELF -> $TEST_ELF"
python3 -m compiler.adder compile \
    --target=x86_64-adder-user \
    tests/test_dir_record_full.ad \
    -o "$TEST_ELF" >/dev/null

echo "[test_dir_record_full] (3/5) Plant /init = hamsh + /bin/test_dir_record_full"
INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py >/dev/null

echo "[test_dir_record_full] (4/5) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

echo "[test_dir_record_full] (5/5) Boot QEMU + drive the test via hamsh"
LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1 || true' EXIT

set +e
# Re-send the test command until its marker appears (per
# feedback_serial_test_first_cmd_dropped).
(
    sleep 3
    for _i in 1 2 3 4; do
        printf '/bin/test_dir_record_full\n'
        sleep 2
    done
    printf 'exit\n'
    sleep 1
) | timeout 45s qemu-system-x86_64 \
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

echo "[test_dir_record_full] --- captured output ---"
cat "$LOG"
echo "[test_dir_record_full] --- end output ---"

fail=0
check_marker() {
    local marker="$1"
    local label="$2"
    if grep -F -q "$marker" "$LOG"; then
        echo "[test_dir_record_full] OK: $label"
    else
        echo "[test_dir_record_full] MISS: $label ($marker)"
        fail=1
    fi
}

check_marker "[dirfull] start"   "fixture ran"
check_marker "[dirfull] tmp OK"  "/tmp Dir records decoded"
check_marker "[dirfull] dev OK"  "/dev Dir records decoded"
check_marker "[dirfull] auth OK" "/dev/auth Dir records decoded"
check_marker "[dirfull] PASS"    "fixture reached PASS"

if [ "$fail" -ne 0 ]; then
    echo "[test_dir_record_full] FAIL (qemu rc=$rc)"
    exit 1
fi

echo "[test_dir_record_full] PASS"
