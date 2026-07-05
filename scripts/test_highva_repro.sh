#!/usr/bin/env bash
# scripts/test_highva_repro.sh -- minimal repro harness for the Firefox
# ld.so eager windowed-mmap PTE=0 fault. Boots the cpio-initramfs kernel
# (fast; no Debian rootfs) with the HOST ld.so + libc.so.6 injected and
# runs u_highva_repro through hamsh.
#
# PASS marker: "HVR: ALL PATTERNS OK"

. "$(dirname "$0")/_build_lock.sh"
. "$(dirname "$0")/_qemu_drive.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

UBIN=tests/u-binary/u_highva_repro
LDSO=/lib64/ld-linux-x86-64.so.2
LIBC=/lib/x86_64-linux-gnu/libc.so.6

if [ ! -f "$(readlink -f "$LDSO")" ] || [ ! -f "$(readlink -f "$LIBC")" ]; then
    echo "[test_highva_repro] SKIP: host ld.so/libc not found"
    exit 0
fi

echo "[test_highva_repro] (1/5) Build repro fixture"
make -C tests/u-binary/src/highva_repro install >/dev/null 2>&1 || true
if [ ! -f "$UBIN" ]; then
    echo "[test_highva_repro] SKIP: $UBIN not built (no host gcc?)"
    exit 0
fi
echo "[test_highva_repro]   $(file -b "$UBIN")"

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf

echo "[test_highva_repro] (2/5) Build userland (hamsh + helpers)"
bash scripts/build_user.sh >/dev/null
bash scripts/build_modules.sh >/dev/null

echo "[test_highva_repro] (3/5) Embed ld.so + libc in initramfs"
HAMNIX_EMBED_UBIN=1 INIT_ELF="$HAMSH_ELF" \
    python3 scripts/build_initramfs.py >/dev/null

LDSO_REAL=$(readlink -f "$LDSO")
LIBC_REAL=$(readlink -f "$LIBC")
python3 - "$LDSO_REAL" "$LIBC_REAL" <<'PYEOF'
import sys
import importlib.util
from pathlib import Path
import os

here = Path.cwd()
spec = importlib.util.spec_from_file_location(
    "build_initramfs", here / "scripts" / "build_initramfs.py")
bi = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bi)

os.environ.setdefault("HAMNIX_EMBED_UBIN", "1")
os.environ.setdefault("INIT_ELF", "build/user/hamsh.elf")
archive = bi.build_archive()
trailer = bi.cpio_trailer()
assert archive.endswith(trailer), "archive shape changed; review me"
archive = archive[:-len(trailer)]

ldso_data = Path(sys.argv[1]).resolve().read_bytes()
print(f"  injecting /lib64/ld-linux-x86-64.so.2 ({len(ldso_data)} bytes)")
archive += bi.cpio_entry("/lib64/ld-linux-x86-64.so.2", ldso_data)

libc_data = Path(sys.argv[2]).resolve().read_bytes()
print(f"  injecting /lib/x86_64-linux-gnu/libc.so.6 ({len(libc_data)} bytes)")
archive += bi.cpio_entry("/lib/x86_64-linux-gnu/libc.so.6", libc_data)

archive += trailer
dest = here / "fs" / "initramfs_blob.S"
bi.emit_asm(archive, dest)
print(f"  rewrote {dest} (total {len(archive)} bytes)")
PYEOF

echo "[test_highva_repro] (4/5) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

echo "[test_highva_repro] (5/5) Boot QEMU + run u_highva_repro via hamsh"
LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null' EXIT

set +e
qemu_drive "$LOG" "$ELF" "[hamsh] M16.35 shell ready" 30 \
    -- "u_highva_repro" 12 \
       "exit" 1
rc="$QEMU_DRIVE_RC"
set -e

echo "[test_highva_repro] --- captured output ---"
cat "$LOG"
echo "[test_highva_repro] --- end output ---"

if grep -a -F -q "HVR: ALL PATTERNS OK" "$LOG"; then
    echo "[test_highva_repro] PASS"
    exit 0
fi
echo "[test_highva_repro] FAIL (qemu rc=$rc): repro did not complete"
exit 1
