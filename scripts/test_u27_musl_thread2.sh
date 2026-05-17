#!/usr/bin/env bash
. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

UBIN=tests/u-binary/u_musl_thread2
[ -f "$UBIN" ] || { echo "[test_u27_musl_thread2] SKIP: $UBIN not built"; exit 0; }

ELF=build/hamnix-vmlinux.elf
HAMSH_ELF=build/user/hamsh.elf

bash scripts/build_user.sh >/dev/null
HAMNIX_EMBED_UBIN=1 INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py >/dev/null
python3 -m compiler.adder compile --target=x86_64-bare-metal init/main.ad -o "$ELF" >/dev/null

LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null' EXIT

(
    sleep 3
    printf 'u_musl_thread2\n'
    sleep 8
    printf 'exit\n'
    sleep 1
) | timeout 20s qemu-system-x86_64 -kernel "$ELF" -smp 2 -nographic -no-reboot -m 256M -monitor none -serial stdio > "$LOG" 2>&1 || true

echo "[test_u27_musl_thread2] --- captured ---"
cat "$LOG"
echo "[test_u27_musl_thread2] --- end ---"

if grep -F -q "U27.2: thread" "$LOG" && grep -F -q "U27.2: main done" "$LOG"; then
    echo "[test_u27_musl_thread2] PASS"
else
    echo "[test_u27_musl_thread2] FAIL"
    exit 1
fi
