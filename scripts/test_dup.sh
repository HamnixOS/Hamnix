#!/usr/bin/env bash
# scripts/test_dup.sh - M16.41 verification.
#
# Drives hamsh through:
#
#     /dup_demo
#     /cat /tmp/dup
#     exit
#
# /dup_demo uses sys_dup to save the current stdout, sys_dup2 to
# point fd 1 at /tmp/dup, writes a marker (which lands in the file,
# NOT serial), then dup2's stdout back. The test asserts:
#
#   - "(restored)" appears on serial → dup_demo's post-restore write
#     reached the actual console (so dup2-to-old-stdout worked).
#   - "DUP_DEMO_MARKER" appears EXACTLY ONCE in the captured log
#     (only after /cat reads it back; never on serial directly).

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-vmlinux.elf
HAMSH_ELF=build/user/hamsh.elf

echo "[test_dup] (1/4) Build userland"
bash scripts/build_user.sh
bash scripts/build_modules.sh

echo "[test_dup] (2/4) Swap /init = $HAMSH_ELF"
INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py

echo "[test_dup] (3/4) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF"

echo "[test_dup] (4/4) Boot QEMU and drive hamsh"
LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null' EXIT

set +e
(
    sleep 3
    printf '/dup_demo\n'
    sleep 1
    printf '/cat /tmp/dup\n'
    sleep 1
    printf 'exit\n'
    sleep 1
) | timeout 15s qemu-system-x86_64 \
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

echo "[test_dup] --- captured output ---"
cat "$LOG"
echo "[test_dup] --- end output ---"

fail=0
if grep -F -q "(restored)" "$LOG"; then
    echo "[test_dup] OK: dup2-back-to-serial worked"
else
    echo "[test_dup] MISS: '(restored)' line never reached serial"
    fail=1
fi
count=$(grep -F -c "DUP_DEMO_MARKER" "$LOG" || true)
if [ "$count" = "1" ]; then
    echo "[test_dup] OK: marker found exactly once (via /cat)"
else
    echo "[test_dup] MISS: 'DUP_DEMO_MARKER' count = $count (expected 1)"
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_dup] FAIL (qemu rc=$rc)"
    exit 1
fi
echo "[test_dup] PASS"
