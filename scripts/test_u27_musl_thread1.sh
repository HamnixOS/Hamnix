#!/usr/bin/env bash
. "$(dirname "$0")/_build_lock.sh"
. "$(dirname "$0")/_qemu_drive.sh"
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

# Prompt-aware drive: wait for hamsh's ready banner before sending input
# (a fixed sleep races boot-time variance -- see _qemu_drive.sh).
qemu_drive "$LOG" "$ELF" "[hamsh] M16.35 shell ready" 20 \
    -- "u_musl_thread1" 8 \
       "exit" 1

echo "[test_u27_musl_thread1] --- captured ---"
cat "$LOG"
echo "[test_u27_musl_thread1] --- end ---"

if grep -a -F -q "U27.1: thread enter" "$LOG" && grep -a -F -q "U27.1: main reaped" "$LOG"; then
    echo "[test_u27_musl_thread1] PASS"
else
    echo "[test_u27_musl_thread1] FAIL"
    exit 1
fi
