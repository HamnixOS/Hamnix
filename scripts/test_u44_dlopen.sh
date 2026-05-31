#!/usr/bin/env bash
# scripts/test_u44_dlopen.sh - §4 item 1: runtime dlopen() / libdl.
#
# U42/U43 proved LOAD-TIME dynamic linking (the kernel loads ld.so;
# ld.so resolves the binary's DT_NEEDED=[libc.so.6] at startup). U44
# proves RUNTIME dlopen(): the u_dlopen_demo binary calls
#
#     h = dlopen("libanswer.so", RTLD_NOW);
#     answer_fn = dlsym(h, "answer");
#     answer_fn()               // == 42
#
# from inside main(). dlopen/dlsym are NOT a Hamnix kernel feature --
# they are provided by the stock glibc ld.so/libc that the §4 loader
# already maps. dlopen() is mechanically identical to a DT_NEEDED
# resolution: open the .so through the process namespace, mmap its
# PT_LOADs with the reserve+overlay idiom, apply RELA relocations,
# run DT_INIT. So a passing run here proves the loader's namespace-
# routed open() + honest mmap (the §4 BSS-zero fix) carry the FULL
# dynamic-linking surface -- DT_NEEDED-at-load-time AND dlopen()-at-
# runtime -- with zero dlopen-specific kernel code.
#
# libanswer.so is a purpose-built one-function DSO -- deliberately NOT
# a glibc library -- so the test isolates the loader's dlopen() path
# from glibc's symbol-versioning / merged-libm / IFUNC machinery.
#
# Staging: this test stages the host's ld.so + libc.so.6 and the
# purpose-built libanswer.so at their canonical FLAT-initramfs paths
# (the simple U42 layout -- U43 already proved the namespace-routed
# variant). libanswer.so is the dlopen() target; it is NOT in the
# binary's DT_NEEDED list, so a successful answer() call means ld.so
# opened it on demand.
#
# Skip-on-missing: no host C compiler / no glibc shared objects ->
# exit 0 with a SKIP message (mirrors test_u42_dynamic_elf).
#
# PASS marker (greppable):  U44 dlopen answer()=42

. "$(dirname "$0")/_build_lock.sh"
. "$(dirname "$0")/_qemu_drive.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

UBIN=tests/u-binary/u_dlopen_demo
DSO=tests/u-binary/u_libanswer.so
HOST_LDSO=/lib64/ld-linux-x86-64.so.2
HOST_LIBC=/lib/x86_64-linux-gnu/libc.so.6

for f in "$HOST_LDSO" "$HOST_LIBC"; do
    if [ ! -e "$f" ] || [ ! -f "$(readlink -f "$f")" ]; then
        echo "[test_u44_dlopen] SKIP: host $f missing"
        exit 0
    fi
done

echo "[test_u44_dlopen] (1/5) Build dlopen_demo fixture + libanswer.so"
make -C tests/u-binary/src/dlopen_demo install >/dev/null 2>&1 || true
if [ ! -f "$UBIN" ] || [ ! -f "$DSO" ]; then
    echo "[test_u44_dlopen] SKIP: fixture not built (no host gcc?)"
    exit 0
fi
echo "[test_u44_dlopen]   $(file -b "$UBIN")"

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf

echo "[test_u44_dlopen] (2/5) Build userland (hamsh + helpers)"
bash scripts/build_user.sh >/dev/null
bash scripts/build_modules.sh >/dev/null

echo "[test_u44_dlopen] (3/5) Embed ld.so + libc.so.6 + libanswer.so"
HAMNIX_EMBED_UBIN=1 INIT_ELF="$HAMSH_ELF" \
    python3 scripts/build_initramfs.py >/dev/null

LDSO_REAL=$(readlink -f "$HOST_LDSO")
LIBC_REAL=$(readlink -f "$HOST_LIBC")
DSO_REAL=$(readlink -f "$DSO")
python3 - "$LDSO_REAL" "$LIBC_REAL" "$DSO_REAL" <<'PYEOF'
import sys
import importlib.util
from pathlib import Path

here = Path.cwd()
spec = importlib.util.spec_from_file_location(
    "build_initramfs", here / "scripts" / "build_initramfs.py")
bi = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bi)

import os
os.environ.setdefault("HAMNIX_EMBED_UBIN", "1")
os.environ.setdefault("INIT_ELF", "build/user/hamsh.elf")
archive = bi.build_archive()
trailer = bi.cpio_trailer()
assert archive.endswith(trailer), "archive shape changed; review me"
archive = archive[:-len(trailer)]

# Interpreter at its canonical /lib64 path.
ldso = Path(sys.argv[1]).resolve().read_bytes()
print(f"  injecting /lib64/ld-linux-x86-64.so.2 ({len(ldso)} bytes)")
archive += bi.cpio_entry("/lib64/ld-linux-x86-64.so.2", ldso)

# libc.so.6 -- the load-time DT_NEEDED. libanswer.so -- the RUNTIME
# dlopen() target. Both at the first entry of ld.so's default x86_64
# search path so they resolve with no ld.so.cache.
libc = Path(sys.argv[2]).resolve().read_bytes()
print(f"  injecting /lib/x86_64-linux-gnu/libc.so.6 ({len(libc)} bytes)")
archive += bi.cpio_entry("/lib/x86_64-linux-gnu/libc.so.6", libc)

dso = Path(sys.argv[3]).resolve().read_bytes()
print(f"  injecting /lib/x86_64-linux-gnu/libanswer.so ({len(dso)} bytes)")
archive += bi.cpio_entry("/lib/x86_64-linux-gnu/libanswer.so", dso)

archive += trailer
dest = here / "fs" / "initramfs_blob.S"
bi.emit_asm(archive, dest)
print(f"  rewrote {dest} (+ld.so +libc +libanswer, total {len(archive)} bytes)")
PYEOF

echo "[test_u44_dlopen] (4/5) Rebuild kernel image"
mkdir -p build
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

echo "[test_u44_dlopen] (5/5) Boot QEMU + run u_dlopen_demo via hamsh"
LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null' EXIT

set +e
# Prompt-aware drive: wait for hamsh's ready banner before sending input
# (a fixed sleep races boot-time variance -- see _qemu_drive.sh).
qemu_drive "$LOG" "$ELF" "[hamsh] M16.35 shell ready" 40 \
    -- "u_dlopen_demo" 6 \
       "exit" 1
rc="$QEMU_DRIVE_RC"
set -e

echo "[test_u44_dlopen] --- captured output ---"
cat "$LOG"
echo "[test_u44_dlopen] --- end output ---"

fail=0

# Load-time linking still works (regression guard). The "dynamic load:
# interp_base=" line is an early kernel printk emitted during exec; under
# the prompt-aware interactive drive it is frequently buffered out of the
# captured window. A successful runtime dlopen() below is impossible
# without the interpreter having loaded, so treat its absence as a DIAG,
# not a failure -- the runtime check is the authoritative signal.
if grep -a -F -q "dynamic load: interp_base=" "$LOG"; then
    echo "[test_u44_dlopen] OK: load-time dynamic link (ld.so loaded)"
else
    echo "[test_u44_dlopen] DIAG: 'dynamic load: interp_base=' printk not in capture (informational)"
fi

# PRIMARY: runtime dlopen() + dlsym() + the resolved call succeeded.
if grep -a -F -q "U44 dlopen answer()=42" "$LOG"; then
    echo "[test_u44_dlopen] OK: runtime dlopen+dlsym+call worked"
else
    echo "[test_u44_dlopen] MISS: 'U44 dlopen answer()=42' absent"
    if grep -a -F -q "U44 dlopen FAILED" "$LOG"; then
        echo "[test_u44_dlopen]   (dlopen returned NULL -- DSO load failed)"
    fi
    if grep -a -F -q "U44 dlsym FAILED" "$LOG"; then
        echo "[test_u44_dlopen]   (dlsym('answer') returned NULL)"
    fi
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_u44_dlopen] FAIL (qemu rc=$rc): runtime dlopen did not work"
    exit 1
fi

echo "[test_u44_dlopen] PASS — runtime dlopen() works on Hamnix!"
exit 0
