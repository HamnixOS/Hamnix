#!/usr/bin/env bash
# scripts/test_p9srv_demo.sh - V4 / Phase D smoke for the userspace
# 9P server scaffold + V4 srv-post/open syscall pair.
#
# Pipeline:
#   1. Build userland (hamsh + coreutils + the new p9srv_demo). The
#      build_user.sh auto-list already calls build_adder_user
#      p9srv_demo so the *.elf lands in build/user/ — and
#      build_initramfs.py's glob embeds it at /bin/p9srv_demo in the
#      cpio.
#   2. Build the fixture tests/test_p9srv_demo.ad to
#      build/user/test_p9srv_demo.elf (also auto-globbed into /bin).
#   3. Plant /init = hamsh.elf so we land at a shell prompt.
#   4. Rebuild the kernel image.
#   5. Boot in QEMU, drive `/bin/test_p9srv_demo` via the serial
#      stdio, then `exit`.
#   6. Grep the serial log for the round-trip markers + PASS.
#
# Markers asserted (from tests/test_p9srv_demo.ad and
# user/p9srv_demo.ad):
#   [p9demo] start
#   [p9demo] srv_post+open OK
#   [p9demo] spawn OK
#   [p9demo] server starting          (server stderr)
#   [p9demo] Rversion OK
#   [p9demo] Rattach OK
#   [p9demo] Rwalk OK
#   [p9demo] Ropen OK
#   [p9demo] Rread OK
#   [p9demo] payload match OK
#   [p9demo] PASS

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-vmlinux.elf
HAMSH_ELF=build/user/hamsh.elf
TEST_ELF=build/user/test_p9srv_demo.elf

echo "[test_p9srv_demo] (1/5) Build userland (hamsh + coreutils + p9srv_demo)"
bash scripts/build_user.sh >/dev/null
bash scripts/build_modules.sh >/dev/null

echo "[test_p9srv_demo] (2/5) Build tests/test_p9srv_demo.ad -> $TEST_ELF"
python3 -m compiler.adder compile \
    --target=x86_64-adder-user \
    tests/test_p9srv_demo.ad \
    -o "$TEST_ELF" >/dev/null

echo "[test_p9srv_demo] (3/5) Plant /init = hamsh + /bin/test_p9srv_demo in cpio"
INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py >/dev/null

echo "[test_p9srv_demo] (4/5) Rebuild kernel image"
mkdir -p build
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

echo "[test_p9srv_demo] (5/5) Boot QEMU + drive the test via hamsh"
LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null' EXIT

set +e
(
    sleep 3
    printf '/bin/test_p9srv_demo\n'
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

echo "[test_p9srv_demo] --- captured output ---"
cat "$LOG"
echo "[test_p9srv_demo] --- end output ---"

fail=0

check_marker() {
    local marker="$1"
    local label="$2"
    if grep -F -q "$marker" "$LOG"; then
        echo "[test_p9srv_demo] OK: $label"
    else
        echo "[test_p9srv_demo] MISS: $label ($marker)"
        fail=1
    fi
}

check_marker "[p9demo] start"             "fixture ran"
check_marker "[p9demo] srv_post+open OK"  "V4 srv-post + srv-open syscalls"
check_marker "[p9demo] spawn OK"          "/bin/p9srv_demo spawned"
check_marker "[p9demo] server starting"   "server printed banner"
check_marker "[p9demo] Rversion OK"       "Tversion round-trip"
check_marker "[p9demo] Rattach OK"        "Tattach round-trip"
check_marker "[p9demo] Rwalk OK"          "Twalk hello round-trip"
check_marker "[p9demo] Ropen OK"          "Topen round-trip"
check_marker "[p9demo] Rread OK"          "Tread round-trip"
check_marker "[p9demo] payload match OK"  "Rread carried 'p9demo says hi\\n'"
check_marker "[p9demo] PASS"              "fixture reached PASS"

if [ "$fail" -ne 0 ]; then
    echo "[test_p9srv_demo] FAIL (qemu rc=$rc)"
    exit 1
fi

echo "[test_p9srv_demo] PASS"
