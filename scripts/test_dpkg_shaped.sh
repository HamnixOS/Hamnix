#!/usr/bin/env bash
# scripts/test_dpkg_shaped.sh - dpkg-shaped fork/exec/reap COW repro.
#
# Tighter, network-free repro of the real-Debian apt-install fault: a
# dynamic parent forks, the child execve()s a DIFFERENT dynamic binary,
# the child exits, the parent REAPS it, and THEN the parent keeps calling
# into ld.so / its own link_map (malloc churn + lazy symbol binding),
# repeated over several rounds. This is the beat the dynamic_forkexec
# canary does NOT exercise (it returns right after the reap). Faults
# deterministically under -smp 1 if a child's execve teardown frees/reuses
# a frame the parent still COW-maps.
#
# PASS marker (greppable):
#   DPKGS: parent survived post-reap dynamic work

. "$(dirname "$0")/_build_lock.sh"
. "$(dirname "$0")/_qemu_drive.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

UBIN=tests/u-binary/u_dpkg_shaped
CHILD_UBIN=tests/u-binary/u_dynamic_hello
ROOTFS=tests/distros/debian-minbase/rootfs
LDSO=$ROOTFS/lib64/ld-linux-x86-64.so.2
LIBC=$ROOTFS/usr/lib/x86_64-linux-gnu/libc.so.6

if [ ! -e "$LDSO" ]; then
    echo "[test_dpkg_shaped] SKIP: $LDSO not staged"
    echo "    Build with: bash tests/distros/debian-minbase/BUILD.sh"
    exit 0
fi
if [ ! -f "$(readlink -f "$LDSO")" ]; then
    echo "[test_dpkg_shaped] SKIP: $LDSO does not resolve to a file"
    exit 0
fi
if [ ! -e "$LIBC" ] || [ ! -f "$(readlink -f "$LIBC")" ]; then
    echo "[test_dpkg_shaped] SKIP: $LIBC not staged or unresolved"
    exit 0
fi

# Prefer the rootfs-internal, libc-matched ld.so (avoids host/rootfs
# glibc ABI skew that looks like a kernel COW regression but isn't).
LIBC_REAL_EARLY=$(readlink -f "$LIBC")
LIBC_DIR=$(dirname "$LIBC_REAL_EARLY")
ROOTFS_LDSO="$LIBC_DIR/ld-linux-x86-64.so.2"
if [ -f "$ROOTFS_LDSO" ]; then
    LDSO="$ROOTFS_LDSO"
fi
glibc_ver() {
    strings "$1" 2>/dev/null \
        | grep -oE 'GLIBC [0-9]+\.[0-9]+' | head -1 | awk '{print $2}'
}
LDSO_GV=$(glibc_ver "$(readlink -f "$LDSO")")
LIBC_GV=$(glibc_ver "$LIBC_REAL_EARLY")
if [ -n "$LDSO_GV" ] && [ -n "$LIBC_GV" ] && [ "$LDSO_GV" != "$LIBC_GV" ]; then
    echo "[test_dpkg_shaped] SKIP: ld.so glibc $LDSO_GV != libc.so.6 glibc $LIBC_GV"
    exit 0
fi
echo "[test_dpkg_shaped]   ld.so glibc=$LDSO_GV libc glibc=$LIBC_GV (matched)"

echo "[test_dpkg_shaped] (1/5) Build dpkg_shaped + dynamic_hello fixtures"
make -C tests/u-binary/src/dpkg_shaped install >/dev/null 2>&1 || true
if [ ! -f "$UBIN" ]; then
    echo "[test_dpkg_shaped] SKIP: $UBIN not built (no host gcc?)"
    exit 0
fi
echo "[test_dpkg_shaped]   $(file -b "$UBIN")"
make -C tests/u-binary/src/dynamic_hello install >/dev/null 2>&1 || true
if [ ! -f "$CHILD_UBIN" ]; then
    echo "[test_dpkg_shaped] SKIP: $CHILD_UBIN not built (no host gcc?)"
    exit 0
fi
echo "[test_dpkg_shaped]   child: $(file -b "$CHILD_UBIN")"

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf

echo "[test_dpkg_shaped] (2/5) Build userland (hamsh + helpers)"
bash scripts/build_user.sh >/dev/null
bash scripts/build_modules.sh >/dev/null

echo "[test_dpkg_shaped] (3/5) Embed ld.so + libc.so.6 in initramfs"
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

ldso_path = Path(sys.argv[1]).resolve()
ldso_data = ldso_path.read_bytes()
print(f"  injecting /lib64/ld-linux-x86-64.so.2 ({len(ldso_data)} bytes)")
archive += bi.cpio_entry("/lib64/ld-linux-x86-64.so.2", ldso_data)

libc_path = Path(sys.argv[2]).resolve()
libc_data = libc_path.read_bytes()
print(f"  injecting /lib/x86_64-linux-gnu/libc.so.6 ({len(libc_data)} bytes)")
archive += bi.cpio_entry("/lib/x86_64-linux-gnu/libc.so.6", libc_data)

archive += trailer
dest = here / "fs" / "initramfs_blob.S"
bi.emit_asm(archive, dest)
print(f"  rewrote {dest} (+ld.so +libc.so.6, total {len(archive)} bytes)")
PYEOF

echo "[test_dpkg_shaped] (4/5) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

echo "[test_dpkg_shaped] (5/5) Boot QEMU (-smp 1) + run u_dpkg_shaped"
LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null' EXIT

set +e
# Force single CPU so any fault is deterministic, not an SMP race.
# QEMU_EXTRA_ARGS is appended AFTER the hardcoded -smp 2, and QEMU honors
# the LAST -smp, so this pins the guest to one vCPU.
QEMU_EXTRA_ARGS="${QEMU_EXTRA_ARGS:-} -smp 1" \
    qemu_drive "$LOG" "$ELF" "[hamsh] M16.35 shell ready" 30 \
    -- "u_dpkg_shaped" 20 \
       "exit" 1
rc="$QEMU_DRIVE_RC"
set -e

echo "[test_dpkg_shaped] --- captured output ---"
cat "$LOG"
echo "[test_dpkg_shaped] --- end output ---"

if grep -a -F -q "DPKGS: parent survived post-reap dynamic work" "$LOG"; then
    echo "[test_dpkg_shaped] PASS — parent survived post-reap ld.so/libc work"
    exit 0
fi

echo "[test_dpkg_shaped] FAIL (qemu rc=$rc): parent did NOT survive" \
     "post-reap dynamic work (COW frame-lifetime fault)"
exit 1
