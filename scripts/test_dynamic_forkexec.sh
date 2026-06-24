#!/usr/bin/env bash
# scripts/test_dynamic_forkexec.sh - U42 dynamic-ELF end-to-end test.
#
# Proves Hamnix can load and run a binary linked against the host's
# /lib64/ld-linux-x86-64.so.2 (the real glibc dynamic linker, ~225 KB
# of PIE shared-object code). All prior U-track work has been static
# or static-PIE: the kernel maps the application's segments, the
# binary's own _start does _dl_relocate_static_pie, and the loader
# never touches PT_INTERP. U42 flips that — the kernel:
#
#   1. Detects PT_INTERP="/lib64/ld-linux-x86-64.so.2".
#   2. Opens that file out of the cpio initramfs as a SECOND ELF.
#   3. Loads ld.so into a fresh memblock region.
#   4. Populates auxv:
#        AT_PHDR  = application's PHDR table   (region+phoff of the app)
#        AT_ENTRY = application's e_entry      (rebased to app base)
#        AT_BASE  = interpreter's load base    (where ld.so lives)
#   5. SYSRETQs to the INTERPRETER's e_entry, not the app's.
#
# ld.so then runs entirely from userspace: walks the application's
# PT_DYNAMIC, processes DT_NEEDED (in our smoke-test case the binary
# is built so the only DSOs it touches via puts() are libc.so.6 and
# the runtime linker itself), applies RELATIVE / GLOB_DAT / JUMP_SLOT
# relocations, runs DT_INIT / DT_INIT_ARRAY, and finally jumps to
# the application's main(), which prints "DYNFE: parent reaped child status=0".
#
# Boot path:
#   1. `make install` builds tests/u-binary/u_dynamic_forkexec (dynamic
#      PIE; PT_INTERP=/lib64/ld-linux-x86-64.so.2).
#   2. A small Python helper invokes build_initramfs.py to assemble
#      the baseline blob (HAMNIX_EMBED_UBIN=1 INIT_ELF=hamsh.elf),
#      then INJECTS the host-side ld.so into the cpio archive at
#      /lib64/ld-linux-x86-64.so.2 so the kernel's PT_INTERP lookup
#      finds it. We don't go through HAMNIX_EMBED_DEBIAN=full (would
#      blow past fs/cpio.ad's NR_FILES cap and GitHub's 100 MB push
#      limit) — only the single ld.so entry is added.
#   3. INIT_ELF=hamsh.elf plants hamsh at /init so the boot drops us
#      at a shell prompt.
#   4. Rebuild the kernel image to incorporate the new initramfs.
#   5. QEMU drives hamsh through `u_dynamic_forkexec`.
#
# Skip-on-missing: if tests/distros/debian-minbase/rootfs/lib64/
# ld-linux-x86-64.so.2 is absent (host hasn't run BUILD.sh to
# debootstrap a Debian rootfs), or if the dynamic_hello binary
# couldn't be built (no host gcc), exit 0 with a SKIP message.
# Mirrors test_u5_linux_binary.sh / test_distro_debian.sh.
#
# PASS marker (greppable):
#   DYNFE: parent reaped child status=0

. "$(dirname "$0")/_build_lock.sh"
. "$(dirname "$0")/_qemu_drive.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

UBIN=tests/u-binary/u_dynamic_forkexec
LDSO=tests/distros/debian-minbase/rootfs/lib64/ld-linux-x86-64.so.2
# ld.so's default DT_NEEDED search path on x86_64 Debian/Ubuntu is
# /lib/x86_64-linux-gnu/ + /usr/lib/x86_64-linux-gnu/ + /lib/ +
# /usr/lib/. Embedding libc.so.6 at the first of these makes the
# dynamic_hello fixture's DT_NEEDED=[libc.so.6] resolvable from
# inside ld.so without any LD_LIBRARY_PATH plumbing.
LIBC=tests/distros/debian-minbase/rootfs/usr/lib/x86_64-linux-gnu/libc.so.6

if [ ! -e "$LDSO" ]; then
    echo "[test_dynamic_forkexec] SKIP: $LDSO not staged"
    echo "    Build with: bash tests/distros/debian-minbase/BUILD.sh"
    echo "    (see tests/distros/debian-minbase/HOWTO.md)"
    exit 0
fi
# ld.so is a symlink to ../lib/x86_64-linux-gnu/ld-linux-x86-64.so.2
# on Debian/Ubuntu — make sure it resolves to a regular file.
if [ ! -f "$(readlink -f "$LDSO")" ]; then
    echo "[test_dynamic_forkexec] SKIP: $LDSO does not resolve to a file"
    exit 0
fi
if [ ! -e "$LIBC" ] || [ ! -f "$(readlink -f "$LIBC")" ]; then
    echo "[test_dynamic_forkexec] SKIP: $LIBC not staged or unresolved"
    exit 0
fi

echo "[test_dynamic_forkexec] (1/5) Build dynamic_hello fixture"
make -C tests/u-binary/src/dynamic_forkexec install >/dev/null 2>&1 || true
if [ ! -f "$UBIN" ]; then
    echo "[test_dynamic_forkexec] SKIP: $UBIN not built (no host gcc?)"
    exit 0
fi
echo "[test_dynamic_forkexec]   $(file -b "$UBIN")"

# The forkexec parent's child execve()s /bin/u_dynamic_hello. That
# second-generation dynamic binary is the dynamic_hello fixture; it
# MUST be built + embedded or the child's execve returns ENOENT and
# the keystone fork->execve(dynamic) path is never exercised.
CHILD_UBIN=tests/u-binary/u_dynamic_hello
make -C tests/u-binary/src/dynamic_hello install >/dev/null 2>&1 || true
if [ ! -f "$CHILD_UBIN" ]; then
    echo "[test_dynamic_forkexec] SKIP: $CHILD_UBIN not built (no host gcc?)"
    exit 0
fi
echo "[test_dynamic_forkexec]   child: $(file -b "$CHILD_UBIN")"

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf

echo "[test_dynamic_forkexec] (2/5) Build userland (hamsh + helpers)"
bash scripts/build_user.sh >/dev/null
bash scripts/build_modules.sh >/dev/null

echo "[test_dynamic_forkexec] (3/5) Embed ld.so + dynamic_hello in initramfs"
HAMNIX_EMBED_UBIN=1 INIT_ELF="$HAMSH_ELF" \
    python3 scripts/build_initramfs.py >/dev/null

# Post-process: inject /lib64/ld-linux-x86-64.so.2 into the cpio
# archive. We import build_initramfs.cpio_entry to keep the binary
# format byte-identical to what the kernel parses. The trailer is
# the last entry in the archive — we splice the ld.so entry in
# BEFORE the trailer and re-emit fs/initramfs_blob.S.
LDSO_REAL=$(readlink -f "$LDSO")
LIBC_REAL=$(readlink -f "$LIBC")
python3 - "$LDSO_REAL" "$LIBC_REAL" <<'PYEOF'
import sys
import importlib.util
from pathlib import Path

here = Path.cwd()
spec = importlib.util.spec_from_file_location(
    "build_initramfs", here / "scripts" / "build_initramfs.py")
bi = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bi)

# Reconstruct the cpio archive: re-running build_archive() reproduces
# the bytes that the .S file already encodes. We then strip the
# trailer, append the ld.so + libc.so.6 entries, re-append the
# trailer, and emit.
import os
os.environ.setdefault("HAMNIX_EMBED_UBIN", "1")
os.environ.setdefault("INIT_ELF", "build/user/hamsh.elf")
archive = bi.build_archive()
trailer = bi.cpio_trailer()
assert archive.endswith(trailer), "archive shape changed; review me"
archive = archive[:-len(trailer)]

ldso_path = Path(sys.argv[1]).resolve()
ldso_data = ldso_path.read_bytes()
print(f"  injecting /lib64/ld-linux-x86-64.so.2 "
      f"({len(ldso_data)} bytes from {ldso_path})")
archive += bi.cpio_entry("/lib64/ld-linux-x86-64.so.2", ldso_data)

# libc.so.6 — what dynamic_hello's DT_NEEDED resolves to. ld.so's
# default search path puts /lib/x86_64-linux-gnu/ first on x86_64
# Debian, so we stage it there. Without /etc/ld.so.cache (we don't
# embed it) ld.so falls back to walking the configured search
# directories — which is exactly the path we want hit.
libc_path = Path(sys.argv[2]).resolve()
libc_data = libc_path.read_bytes()
print(f"  injecting /lib/x86_64-linux-gnu/libc.so.6 "
      f"({len(libc_data)} bytes from {libc_path})")
archive += bi.cpio_entry("/lib/x86_64-linux-gnu/libc.so.6", libc_data)

archive += trailer

dest = here / "fs" / "initramfs_blob.S"
bi.emit_asm(archive, dest)
print(f"  rewrote {dest} (+ld.so +libc.so.6, total {len(archive)} bytes)")
PYEOF

echo "[test_dynamic_forkexec] (4/5) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

echo "[test_dynamic_forkexec] (5/5) Boot QEMU + run u_dynamic_forkexec via hamsh"
LOG=$(mktemp)
# Restore the baseline default initramfs on exit so subsequent tests
# (and a clean repo state) don't carry forward the +ld.so form.
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null' EXIT

set +e
# Prompt-aware drive: wait for hamsh's ready banner before sending input
# (a fixed sleep races boot-time variance -- see _qemu_drive.sh).
qemu_drive "$LOG" "$ELF" "[hamsh] M16.35 shell ready" 30 \
    -- "u_dynamic_forkexec" 8 \
       "exit" 1
rc="$QEMU_DRIVE_RC"
set -e

echo "[test_dynamic_forkexec] --- captured output ---"
cat "$LOG"
echo "[test_dynamic_forkexec] --- end output ---"

fail=0
infra_ok=0

# PRIMARY pass criterion: the application's main() was reached and
# puts() landed on serial. With the per-task VMA layer (mm/vma.ad)
# this is now the hard pass — the kernel-side bookkeeping that ld.so
# needs (MAP_FIXED inside an existing reservation, mprotect of the
# overlay region, munmap of unused tail) is honest, so once ld.so
# transfers control to the app's _start the application's puts()
# should reach the serial port.
if grep -a -F -q "DYNFE: parent reaped child status=0" "$LOG"; then
    echo "[test_dynamic_forkexec] OK: u_dynamic_forkexec forked + reaped"
else
    echo "[test_dynamic_forkexec] MISS: 'DYNFE: parent reaped child status=0' did not" \
         "land on serial"
    fail=1
fi

# Supporting kernel-side checks (must still fire — they prove
# fs/elf.ad's PT_INTERP arm + auxv plumbing didn't regress).

# 1. fs/elf.ad detected PT_INTERP and printed the interp path.
if grep -a -F -q "PT_INTERP=" "$LOG"; then
    echo "[test_dynamic_forkexec] OK: PT_INTERP detected by loader"
    infra_ok=$((infra_ok + 1))
else
    echo "[test_dynamic_forkexec] MISS: no PT_INTERP detect printk"
    fail=1
fi

# 2. fs/elf.ad's recursive load completed — the interpreter base +
#    entry pair was printed.
if grep -a -F -q "dynamic load: interp_base=" "$LOG"; then
    echo "[test_dynamic_forkexec] OK: interpreter loaded at distinct base"
    infra_ok=$((infra_ok + 1))
else
    echo "[test_dynamic_forkexec] MISS: no 'dynamic load' printk" \
         "(interp load failed)"
    fail=1
fi

# 3. Linux-ABI detection.
if grep -a -F -q "Linux-ABI binary detected" "$LOG"; then
    echo "[test_dynamic_forkexec] OK: ELF loader detected Linux-ABI"
    infra_ok=$((infra_ok + 1))
else
    echo "[test_dynamic_forkexec] MISS: no 'Linux-ABI binary detected'"
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_dynamic_forkexec] FAIL (qemu rc=$rc):" \
         "U42 dynamic ELF did not run end-to-end"
    exit 1
fi

echo "[test_dynamic_forkexec] PASS — first dynamic ELF on Hamnix!" \
     "($infra_ok/3 kernel-side checks + main() reached)"
exit 0
