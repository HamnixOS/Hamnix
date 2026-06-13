#!/usr/bin/env bash
# scripts/test_p9_dir.sh - #458 F10-6 acceptance gate. Boots QEMU,
# runs tests/test_p9_dir.elf which exercises the new
# SYS_LISTDIR_RECORDS (318) syscall + devsrv_list_dir kernel emitter
# + p9_diread userspace cursor.
#
# Markers asserted (from tests/test_p9_dir.ad):
#   [p9dir] start
#   [p9dir] posted
#   [p9dir] listdir_records OK
#   [p9dir] dir record decoded
#   [p9dir] name match OK
#   [p9dir] uid match OK
#   [p9dir] mode match OK
#   [p9dir] PASS

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf
TEST_ELF=build/user/test_p9_dir.elf

echo "[test_p9_dir] (1/5) Build userland (hamsh + coreutils)"
bash scripts/build_user.sh >/dev/null
bash scripts/build_modules.sh >/dev/null

echo "[test_p9_dir] (2/5) Build tests/test_p9_dir.ad -> $TEST_ELF"
python3 -m compiler.adder compile \
    --target=x86_64-adder-user \
    tests/test_p9_dir.ad \
    -o "$TEST_ELF" >/dev/null

echo "[test_p9_dir] (3/5) Plant /init = hamsh + /bin/test_p9_dir in cpio"
INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py >/dev/null

echo "[test_p9_dir] (4/5) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

echo "[test_p9_dir] (5/5) Boot QEMU + drive the test via hamsh"
LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null' EXIT

set +e
# Per feedback_serial_test_first_cmd_dropped: re-send the test command
# until its [p9dir] start marker shows up. hamsh swallows the first
# serial line after the prompt.
(
    sleep 3
    for _i in 1 2 3 4; do
        printf '/bin/test_p9_dir\n'
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

echo "[test_p9_dir] --- captured output ---"
cat "$LOG"
echo "[test_p9_dir] --- end output ---"

fail=0

check_marker() {
    local marker="$1"
    local label="$2"
    if grep -F -q "$marker" "$LOG"; then
        echo "[test_p9_dir] OK: $label"
    else
        echo "[test_p9_dir] MISS: $label ($marker)"
        fail=1
    fi
}

check_marker "[p9dir] start"               "fixture ran"
check_marker "[p9dir] posted"              "sys_srv_post returned 0"
check_marker "[p9dir] listdir_records OK"  "SYS_LISTDIR_RECORDS returned bytes"
check_marker "[p9dir] dir record decoded"  "p9_diread decoded at least one record"
check_marker "[p9dir] name match OK"       "saw 'dirtest' in Dir.name"
check_marker "[p9dir] uid match OK"        "Dir.uid == 'hostowner'"
check_marker "[p9dir] mode match OK"       "Dir.mode == 0444"
check_marker "[p9dir] PASS"                "fixture reached PASS"

if [ "$fail" -ne 0 ]; then
    echo "[test_p9_dir] FAIL (qemu rc=$rc)"
    exit 1
fi

echo "[test_p9_dir] PASS"
