#!/usr/bin/env bash
# scripts/test_9p_v3_defaults.sh — 9P V3 regression.
#
# Boots Hamnix in QEMU and proves the Plan 9 root-namespace defaults
# come up wired:
#
#   - `/srv` directory exists and is empty at boot (no posted servers).
#   - `/proc/1/ns` returns at least 0 bytes (synthetic text file).
#   - `/n` directory exists and is empty.
#   - A child task that rfork(RFNAMEG)+bind sees its bind in
#     `/proc/<child>/ns`; parent's `/proc/1/ns` is untouched.
#
# Markers (greppable):
#   [v3-defaults] start
#   [v3-srv-empty] OK
#   [v3-procns-init] OK
#   [v3-n-empty] OK
#   [v3-child-ns] OK
#   [v3-parent-clean] OK
#   [v3-defaults] PASS

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-vmlinux.elf
HAMSH_ELF=build/user/hamsh.elf
TEST_ELF=build/user/test_9p_v3_defaults.elf

echo "[test_9p_v3_defaults] (1/5) Build userland (hamsh + coreutils)"
bash scripts/build_user.sh >/dev/null
bash scripts/build_modules.sh >/dev/null

echo "[test_9p_v3_defaults] (2/5) Build tests/test_9p_v3_defaults.ad -> $TEST_ELF"
python3 -m compiler.adder compile \
    --target=x86_64-adder-user \
    tests/test_9p_v3_defaults.ad \
    -o "$TEST_ELF" >/dev/null

echo "[test_9p_v3_defaults] (3/5) Plant /init = hamsh + /bin/test_9p_v3_defaults in cpio"
INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py >/dev/null

echo "[test_9p_v3_defaults] (4/5) Rebuild kernel image"
mkdir -p build
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

echo "[test_9p_v3_defaults] (5/5) Boot QEMU + drive the test via hamsh"
LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null' EXIT

set +e
(
    # Match scripts/test_ns_isolation.sh pacing — let the kernel finish
    # smoke tests + sched_init before hamsh starts reading stdin.
    sleep 3
    printf '/bin/test_9p_v3_defaults\n'
    sleep 4
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

echo "[test_9p_v3_defaults] --- captured output ---"
cat "$LOG"
echo "[test_9p_v3_defaults] --- end output ---"

fail=0

if grep -F -q "[v3-defaults] start" "$LOG"; then
    echo "[test_9p_v3_defaults] OK: fixture ran"
else
    echo "[test_9p_v3_defaults] MISS: fixture banner missing"
    fail=1
fi

if grep -F -q "[v3-srv-empty] OK" "$LOG"; then
    echo "[test_9p_v3_defaults] OK: /srv directory served"
else
    echo "[test_9p_v3_defaults] MISS: /srv directory failed"
    fail=1
fi

if grep -F -q "[v3-procns-init] OK" "$LOG"; then
    echo "[test_9p_v3_defaults] OK: /proc/1/ns served"
else
    echo "[test_9p_v3_defaults] MISS: /proc/1/ns failed"
    fail=1
fi

if grep -F -q "[v3-n-empty] OK" "$LOG"; then
    echo "[test_9p_v3_defaults] OK: /n directory served"
else
    echo "[test_9p_v3_defaults] MISS: /n directory failed"
    fail=1
fi

if grep -F -q "[v3-child-ns] OK" "$LOG"; then
    echo "[test_9p_v3_defaults] OK: child's bind reflected in /proc/<child>/ns"
else
    echo "[test_9p_v3_defaults] MISS: child ns dispatch broken"
    fail=1
fi

if grep -F -q "[v3-parent-clean] OK" "$LOG"; then
    echo "[test_9p_v3_defaults] OK: parent's /proc/1/ns isolated from child"
else
    echo "[test_9p_v3_defaults] MISS: parent's ns leaked child binding"
    fail=1
fi

if grep -F -q "[v3-defaults] PASS" "$LOG"; then
    echo "[test_9p_v3_defaults] OK: fixture reached PASS"
else
    echo "[test_9p_v3_defaults] MISS: PASS line absent"
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_9p_v3_defaults] FAIL (qemu rc=$rc)"
    exit 1
fi

echo "[test_9p_v3_defaults] PASS"
