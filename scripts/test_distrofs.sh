#!/usr/bin/env bash
# scripts/test_distrofs.sh — smoke for user/distrofs.ad, the userland
# 9P file-server daemon that exports a distro-shaped /var tree.
#
# Pipeline (mirrors scripts/test_p9srv_demo.sh):
#   1. Build userland (hamsh + coreutils + the new distrofs). The
#      build_user.sh auto-list already calls build_adder_user distrofs
#      so the .elf lands in build/user/ and build_initramfs.py's glob
#      embeds it at /bin/distrofs in the cpio.
#   2. Build the fixture tests/test_distrofs.ad to
#      build/user/test_distrofs.elf (also auto-globbed into /bin).
#   3. Plant /init = hamsh.elf so we land at a shell prompt.
#   4. Rebuild the kernel image.
#   5. Boot in QEMU, drive /bin/test_distrofs via serial stdio, exit.
#   6. Grep the serial log for the round-trip markers + PASS.
#
# Markers asserted (from tests/test_distrofs.ad and user/distrofs.ad):
#   [distrofs] start
#   [distrofs] spawn OK
#   [distrofs] server starting        (server stderr)
#   [distrofs] Rversion OK
#   [distrofs] Rattach OK
#   [distrofs] Rwalk dpkg OK
#   [distrofs] Rcreate OK
#   [distrofs] Rwrite OK
#   [distrofs] Rwalk status OK
#   [distrofs] Ropen OK
#   [distrofs] payload match OK
#   [distrofs] Rstat dir OK
#   [distrofs] PASS

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf
TEST_ELF=build/user/test_distrofs.elf

echo "[test_distrofs] (1/5) Build userland (hamsh + coreutils + distrofs)"
bash scripts/build_user.sh >/dev/null
bash scripts/build_modules.sh >/dev/null

echo "[test_distrofs] (2/5) Build tests/test_distrofs.ad -> $TEST_ELF"
python3 -m compiler.adder compile \
    --target=x86_64-adder-user \
    tests/test_distrofs.ad \
    -o "$TEST_ELF" >/dev/null

echo "[test_distrofs] (3/5) Plant /init = hamsh + /bin/test_distrofs in cpio"
INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py >/dev/null

echo "[test_distrofs] (4/5) Rebuild kernel image"
mkdir -p build
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

echo "[test_distrofs] (5/5) Boot QEMU + drive the test via hamsh"
LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null' EXIT

set +e
(
    sleep 3
    printf '/bin/test_distrofs\n'
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

echo "[test_distrofs] --- captured output ---"
cat "$LOG"
echo "[test_distrofs] --- end output ---"

fail=0

check_marker() {
    local marker="$1"
    local label="$2"
    if grep -F -q "$marker" "$LOG"; then
        echo "[test_distrofs] OK: $label"
    else
        echo "[test_distrofs] MISS: $label ($marker)"
        fail=1
    fi
}

# Any per-assertion FAIL line means the round-trip broke somewhere.
if grep -F -q "[distrofs] FAIL:" "$LOG"; then
    echo "[test_distrofs] MISS: per-assertion FAIL line(s) present:"
    grep -F "[distrofs] FAIL:" "$LOG" | sed 's/^/  /'
    fail=1
else
    echo "[test_distrofs] OK: no per-assertion FAIL lines"
fi

check_marker "[distrofs] start"           "fixture ran"
check_marker "[distrofs] spawn OK"        "/bin/distrofs spawned"
check_marker "[distrofs] server starting" "daemon printed banner"
check_marker "[distrofs] Rversion OK"     "Tversion round-trip"
check_marker "[distrofs] Rattach OK"      "Tattach round-trip"
check_marker "[distrofs] Rwalk dpkg OK"   "Twalk var/lib/dpkg round-trip"
check_marker "[distrofs] Rcreate OK"      "Tcreate status file"
check_marker "[distrofs] Rwrite OK"       "Twrite payload bytes"
check_marker "[distrofs] Rwalk status OK" "re-walk to created file"
check_marker "[distrofs] Ropen OK"        "Topen round-trip"
check_marker "[distrofs] payload match OK" "Tread returned written bytes"
check_marker "[distrofs] Rstat dir OK"    "Tstat of a directory"
check_marker "[distrofs] PASS"            "fixture reached PASS"

if [ "$fail" -ne 0 ]; then
    echo "[test_distrofs] FAIL (qemu rc=$rc)"
    exit 1
fi

echo "[test_distrofs] PASS"
