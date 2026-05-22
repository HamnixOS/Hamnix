#!/usr/bin/env bash
# scripts/test_namec_chan.sh — Phase D: prove a mounted 9P server is
# opened + read through the universal namec()/devtab path.
#
# Phase D inverted the resource path so a local-device Chan and a
# mounted-9P Chan are the SAME type with the SAME operation interface,
# resolved through namec() (sys/src/9/port/namec.ad). Before Phase D a
# 9P-mounted file went through fs/vfs.ad's FD_P9_MARK special-case; now
# vfs_open routes it through namec(), which produces a DEV_MNT Chan and
# installs a unified FD_CHAN_MARK fd dispatched via mountrpc.
#
# This test reuses the V4.1 end-to-end fixture (tests/test_9p_e2e.ad):
# it spawns a userspace 9P server, mounts it, opens "/n/demo/hello",
# reads it, and compares the payload. The fixture's success markers
# prove the full Plan-9 loop still closes. ON TOP of that, this test
# asserts the kernel printed the Phase-D proof line
#
#     [namec] mounted-9P chan opened via namec (DEV_MNT)
#
# which fs/vfs.ad::_namec_open emits exactly when namec() resolves a
# mounted-9P Chan — i.e. the open went through namec/devtab, not the
# legacy FD_P9_MARK arm.
#
# Pipeline mirrors scripts/test_9p_e2e.sh.

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf
TEST_ELF=build/user/test_9p_e2e.elf

echo "[test_namec_chan] (1/5) Build userland (hamsh + coreutils + p9srv_demo)"
bash scripts/build_user.sh >/dev/null
bash scripts/build_modules.sh >/dev/null

echo "[test_namec_chan] (2/5) Build tests/test_9p_e2e.ad -> $TEST_ELF"
python3 -m compiler.adder compile \
    --target=x86_64-adder-user \
    tests/test_9p_e2e.ad \
    -o "$TEST_ELF" >/dev/null

echo "[test_namec_chan] (3/5) Plant /init = hamsh + /bin/test_9p_e2e in cpio"
INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py >/dev/null

echo "[test_namec_chan] (4/5) Rebuild kernel image"
mkdir -p build
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

echo "[test_namec_chan] (5/5) Boot QEMU + drive the test via hamsh"
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

echo "[test_namec_chan] --- captured output ---"
cat "$LOG"
echo "[test_namec_chan] --- end output ---"

fail=0

check_marker() {
    local marker="$1"
    local label="$2"
    if grep -F -q "$marker" "$LOG"; then
        echo "[test_namec_chan] OK: $label"
    else
        echo "[test_namec_chan] MISS: $label ($marker)"
        fail=1
    fi
}

# The full Plan-9 loop still closes (fixture markers).
check_marker "[p9_e2e] mount OK"   "sys_mount completed Tversion+Tattach"
check_marker "[p9_e2e] open OK"    "sys_open routed through kernel 9P client"
check_marker "[p9_e2e] payload OK" "Rread carried 'p9demo says hi'"
check_marker "[p9_e2e] PASS"       "fixture reached PASS"

# Phase D proof: the mounted-9P open resolved through namec/devtab.
check_marker "[namec] mounted-9P chan opened via namec (DEV_MNT)" \
    "mounted 9P server opened + read through namec() — no FD_P9_MARK"

if [ "$fail" -ne 0 ]; then
    echo "[test_namec_chan] FAIL (qemu rc=$rc)"
    exit 1
fi

echo "[test_namec_chan] PASS"
