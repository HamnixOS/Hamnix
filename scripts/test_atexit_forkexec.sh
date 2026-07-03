#!/usr/bin/env bash
# scripts/test_atexit_forkexec.sh — tighter repro for the XWayland
# fork+exec .bss exit-list COW corruption (Phase-5c X-display gate).
#
# The u_atexit_forkexec fixture registers atexit() handlers, fork+execve's
# /bin/u_dynamic_hello a few times, verifies its COW-shared .bss table is
# intact, then returns from main() so glibc __run_exit_handlers CALLS each
# handler. A COW-teardown corruption of the parent's .bss shows up as either
# a "bss table CORRUPTED" line or an NX exec-fault when a scribbled exit
# handler pointer is called.
#
# Uses the HOST's own ld.so + libc.so.6 (ABI-matched to the host cc that
# builds the fixture), injected into the initramfs — no debootstrap needed.
# Boots serial-only via the GRUB-ISO qemu_drive path (no -kernel, no -vga).
#
# PASS marker: "AXFE: PASS all exit handlers ran"

. "$(dirname "$0")/_build_lock.sh"
. "$(dirname "$0")/_qemu_drive.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

UBIN=tests/u-binary/u_atexit_forkexec
CHILD_UBIN=tests/u-binary/u_dynamic_hello

command -v cc >/dev/null 2>&1 || { echo "[test_atexit_forkexec] SKIP: no host cc"; exit 0; }

# Host ld.so + libc (ABI-matched to the host cc used below).
LDSO_REAL=$(readlink -f /lib64/ld-linux-x86-64.so.2 2>/dev/null || true)
LIBC_REAL=$(readlink -f /lib/x86_64-linux-gnu/libc.so.6 2>/dev/null || true)
[ -f "$LDSO_REAL" ] || { echo "[test_atexit_forkexec] SKIP: host ld.so missing"; exit 0; }
[ -f "$LIBC_REAL" ] || { echo "[test_atexit_forkexec] SKIP: host libc missing"; exit 0; }
echo "[test_atexit_forkexec] host ld.so=$LDSO_REAL libc=$LIBC_REAL"

echo "[test_atexit_forkexec] (1/5) Build fixtures"
make -C tests/u-binary/src/atexit_forkexec install >/dev/null 2>&1 || true
make -C tests/u-binary/src/dynamic_hello  install >/dev/null 2>&1 || true
[ -f "$UBIN" ] || { echo "[test_atexit_forkexec] SKIP: $UBIN not built"; exit 0; }
[ -f "$CHILD_UBIN" ] || { echo "[test_atexit_forkexec] SKIP: $CHILD_UBIN not built"; exit 0; }
echo "[test_atexit_forkexec]   $(file -b "$UBIN")"

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf

echo "[test_atexit_forkexec] (2/5) Build userland"
bash scripts/build_user.sh >/dev/null
bash scripts/build_modules.sh >/dev/null

echo "[test_atexit_forkexec] (3/5) Embed ld.so + libc in initramfs"
HAMNIX_EMBED_UBIN=1 INIT_ELF="$HAMSH_ELF" \
    python3 scripts/build_initramfs.py >/dev/null

python3 - "$LDSO_REAL" "$LIBC_REAL" <<'PYEOF'
import sys, os
import importlib.util
from pathlib import Path
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
ldso = Path(sys.argv[1]).read_bytes()
archive += bi.cpio_entry("/lib64/ld-linux-x86-64.so.2", ldso)
libc = Path(sys.argv[2]).read_bytes()
archive += bi.cpio_entry("/lib/x86_64-linux-gnu/libc.so.6", libc)
archive += trailer
dest = here / "fs" / "initramfs_blob.S"
bi.emit_asm(archive, dest)
print(f"  rewrote {dest} (+ld.so +libc.so.6, total {len(archive)} bytes)")
PYEOF

echo "[test_atexit_forkexec] (4/5) Rebuild kernel image"
python3 -m compiler.adder compile --target=x86_64-bare-metal \
    init/main.ad -o "$ELF" >/dev/null

echo "[test_atexit_forkexec] (5/5) Boot QEMU + run u_atexit_forkexec"
LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1 || true' EXIT

set +e
qemu_drive "$LOG" "$ELF" "[hamsh] M16.35 shell ready" 40 \
    -- "u_atexit_forkexec" 12 \
       "exit" 1
rc="$QEMU_DRIVE_RC"
set -e

echo "[test_atexit_forkexec] --- captured output ---"
cat "$LOG"
echo "[test_atexit_forkexec] --- end output ---"

if grep -a -F -q "AXFE: PASS all exit handlers ran" "$LOG"; then
    echo "[test_atexit_forkexec] PASS — parent exit handlers ran, .bss COW intact"
    exit 0
fi
if grep -a -F -q "AXFE: FAIL bss table CORRUPTED" "$LOG"; then
    echo "[test_atexit_forkexec] REPRO — .bss table corrupted by child exec teardown"
    exit 1
fi
if grep -a -E -q "NX exec-fault|bss table CORRUPTED|handler ran tag=last" "$LOG"; then
    echo "[test_atexit_forkexec] REPRO/partial — see exit-handler / NX lines above"
    exit 1
fi
echo "[test_atexit_forkexec] MISS: PASS marker not seen (rc=$rc)"
exit 1
