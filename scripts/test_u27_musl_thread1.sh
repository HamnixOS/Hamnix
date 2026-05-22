#!/usr/bin/env bash
. "$(dirname "$0")/_build_lock.sh"
. "$(dirname "$0")/_ensure_ubin.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

UBIN=tests/u-binary/u_musl_thread1
# Build-on-missing: the fixture is gitignored (host-built). If absent,
# build it from tests/u-binary/src/musl_thread1; only SKIP on a real
# build failure.
ensure_ubin_or_skip test_u27_musl_thread1 u_musl_thread1 musl_thread1

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf

bash scripts/build_user.sh >/dev/null
HAMNIX_EMBED_UBIN=1 INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py >/dev/null
python3 -m compiler.adder compile --target=x86_64-bare-metal init/main.ad -o "$ELF" >/dev/null

LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null' EXIT

(
    sleep 3
    printf 'u_musl_thread1\n'
    sleep 8
    printf 'exit\n'
    sleep 1
) | timeout 20s qemu-system-x86_64 -kernel "$ELF" -smp 2 -nographic -no-reboot -m 256M -monitor none -serial stdio > "$LOG" 2>&1 || true

echo "[test_u27_musl_thread1] --- captured ---"
cat "$LOG"
echo "[test_u27_musl_thread1] --- end ---"

if grep -F -q "U27.1: thread enter" "$LOG" && grep -F -q "U27.1: main reaped" "$LOG"; then
    echo "[test_u27_musl_thread1] PASS"
else
    echo "[test_u27_musl_thread1] FAIL"
    exit 1
fi
