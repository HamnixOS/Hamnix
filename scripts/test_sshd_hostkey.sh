#!/usr/bin/env bash
# scripts/test_sshd_hostkey.sh — SSH server host-key generate +
# persist regression.
#
# user/sshd.ad generates its ECDSA-P256 host key from /dev/random on
# first start and persists it to /var/lib/ssh/ssh_host_ecdsa_key, so
# each system keeps a stable host identity across restarts. This test
# builds tests/test_sshd_hostkey.ad as a userland ELF, plants it at
# /bin/test_sshd_hostkey, boots QEMU + hamsh, runs the binary, and
# greps the serial log for the [hostkey] PASS banner.
#
# The fixture drives the exact generate-persist-reload cycle sshd's
# _generate_host_key / _load_host_key use, asserting the persisted key
# round-trips byte-for-byte, the public point is stable across reload,
# and a corrupt (all-zero) key is rejected by the range check.
#
# PASS criterion: "[hostkey] failures=0" AND "[hostkey] PASS" both in
# the serial log. Shape borrowed from scripts/test_ecdsa_verify.sh.

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-vmlinux.elf
HAMSH_ELF=build/user/hamsh.elf
TEST_ELF=build/user/test_sshd_hostkey.elf

echo "[test_sshd_hostkey] (1/5) Build userland (hamsh + coreutils)"
bash scripts/build_user.sh >/dev/null
bash scripts/build_modules.sh >/dev/null

echo "[test_sshd_hostkey] (2/5) Build tests/test_sshd_hostkey.ad -> $TEST_ELF"
python3 -m compiler.adder compile \
    --target=x86_64-adder-user \
    tests/test_sshd_hostkey.ad \
    -o "$TEST_ELF" >/dev/null

echo "[test_sshd_hostkey] (3/5) Plant /init = hamsh + /bin/test_sshd_hostkey"
INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py >/dev/null

echo "[test_sshd_hostkey] (4/5) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

echo "[test_sshd_hostkey] (5/5) Boot QEMU + drive /bin/test_sshd_hostkey"
LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null' EXIT

set +e
(
    sleep 3
    printf '/bin/test_sshd_hostkey\n'
    sleep 15
    printf 'exit\n'
    sleep 1
) | timeout 90s qemu-system-x86_64 \
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

echo "[test_sshd_hostkey] --- captured output ---"
cat "$LOG"
echo "[test_sshd_hostkey] --- end output ---"

fail=0

if grep -F -q "[hostkey] start" "$LOG"; then
    echo "[test_sshd_hostkey] OK: fixture ran"
else
    echo "[test_sshd_hostkey] MISS: fixture banner missing"
    fail=1
fi

if grep -F -q "[hostkey] FAIL:" "$LOG"; then
    echo "[test_sshd_hostkey] MISS: per-assertion FAIL line(s) present:"
    grep -F "[hostkey] FAIL:" "$LOG" | sed 's/^/  /'
    fail=1
else
    echo "[test_sshd_hostkey] OK: no per-assertion FAIL lines"
fi

if grep -F -q "[hostkey] failures=0" "$LOG"; then
    echo "[test_sshd_hostkey] OK: failures=0"
else
    echo "[test_sshd_hostkey] MISS: failures=0 absent"
    fail=1
fi

if grep -F -q "[hostkey] PASS" "$LOG"; then
    echo "[test_sshd_hostkey] OK: fixture reached PASS"
else
    echo "[test_sshd_hostkey] MISS: PASS line absent"
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_sshd_hostkey] FAIL (qemu rc=$rc)"
    exit 1
fi

echo "[test_sshd_hostkey] PASS"
