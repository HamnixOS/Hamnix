#!/usr/bin/env bash
# scripts/test_u43_dynamic_namespace.sh - §4 capstone: a dynamically-
# linked Linux binary exec'd INSIDE a distro-shaped namespace.
#
# This is the proof that the §4 loader work is namespace-correct.
# test_u42_dynamic_elf.sh already proved Hamnix can load a dynamic
# ELF when its interpreter (/lib64/ld-linux-x86-64.so.2) and its
# DT_NEEDED libc.so.6 sit at their canonical paths in the FLAT
# initramfs. That test resolved everything through the raw, namespace-
# AGNOSTIC initramfs_data_* accessors.
#
# U43 closes the loop: it stages ld.so + libc.so.6 + the dynamic
# binary into a per-distro BACKING tree (/var/lib/distros/dyndistro/)
# and runs the binary via /bin/distrorun, which:
#
#   1. rfork(RFNAMEG) — privatises the calling task's namespace.
#   2. bind("/lib64", backing/lib64) — grafts the distro's ld.so.
#   3. bind("/lib",   backing/lib)   — grafts the distro's libc.so.6.
#   4. exec("/bin/u_dynamic_ns_hello") — the dynamic binary itself.
#
# Inside that namespace the kernel ELF loader's PT_INTERP lookup
# (fs/elf.ad::_load_interp_elf → ns_blob_ptr → resolve_path) rewrites
# "/lib64/ld-linux-x86-64.so.2" through the bind to
# "/var/lib/distros/dyndistro/lib64/ld-linux-x86-64.so.2" and finds
# ld.so in the DISTRO tree — NOT a hardcoded global path. ld.so then
# opens "/lib/x86_64-linux-gnu/libc.so.6", which vfs_open resolves
# through the SAME namespace bind to the distro's libc.so.6.
#
# The binary itself (/bin/u_dynamic_ns_hello) is left in Hamnix's native
# /bin — distrorun deliberately does not bind /bin (see distrorun.ad).
# So this test exercises the precise split the §4 mission asked for:
# binary resolved natively, interpreter + library resolved through
# the namespace.
#
# Self-contained: it stages the HOST's own glibc (every Linux dev box
# has /lib64/ld-linux-x86-64.so.2 + libc.so.6) — no debootstrap'd
# rootfs required. Nothing is committed to the repo; the staged files
# are injected into the cpio archive at build time and the baseline
# initramfs is restored on exit.
#
# Skip-on-missing: if the host has no C compiler or no glibc shared
# objects, exit 0 with a SKIP message (mirrors test_u42_dynamic_elf).
#
# PASS marker (greppable):  U43 dynamic-ns hello

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

UBIN=tests/u-binary/u_dynamic_ns_hello
HOST_LDSO=/lib64/ld-linux-x86-64.so.2
HOST_LIBC=/lib/x86_64-linux-gnu/libc.so.6

# The host's runtime linker + libc. On Debian/Ubuntu both are present
# on virtually every box (package libc6). Resolve symlinks to regular
# files so the cpio injector reads real bytes.
if [ ! -e "$HOST_LDSO" ] || [ ! -f "$(readlink -f "$HOST_LDSO")" ]; then
    echo "[test_u43_dynamic_namespace] SKIP: host $HOST_LDSO missing"
    exit 0
fi
if [ ! -e "$HOST_LIBC" ] || [ ! -f "$(readlink -f "$HOST_LIBC")" ]; then
    echo "[test_u43_dynamic_namespace] SKIP: host $HOST_LIBC missing"
    exit 0
fi

echo "[test_u43_dynamic_namespace] (1/5) Build dynamic_ns_hello fixture"
make -C tests/u-binary/src/dynamic_ns_hello install >/dev/null 2>&1 || true
if [ ! -f "$UBIN" ]; then
    echo "[test_u43_dynamic_namespace] SKIP: $UBIN not built (no host gcc?)"
    exit 0
fi
echo "[test_u43_dynamic_namespace]   $(file -b "$UBIN")"

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf

echo "[test_u43_dynamic_namespace] (2/5) Build userland (hamsh + distrorun)"
bash scripts/build_user.sh >/dev/null
bash scripts/build_modules.sh >/dev/null

echo "[test_u43_dynamic_namespace] (3/5) Embed dyndistro backing + binary"
HAMNIX_EMBED_UBIN=1 INIT_ELF="$HAMSH_ELF" \
    python3 scripts/build_initramfs.py >/dev/null

# Post-process: inject the dynamic linker + libc.so.6 into the cpio
# archive UNDER THE DISTRO BACKING TREE (not their canonical global
# paths). distrorun's bind() grafts these onto /lib64 and /lib inside
# the namespace, and the kernel loader's namespace-aware lookup
# resolves the PT_INTERP / DT_NEEDED paths through that bind.
LDSO_REAL=$(readlink -f "$HOST_LDSO")
LIBC_REAL=$(readlink -f "$HOST_LIBC")
python3 - "$LDSO_REAL" "$LIBC_REAL" <<'PYEOF'
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

# Stage ld.so + libc.so.6 INSIDE the distro backing tree. distrorun
# binds /var/lib/distros/dyndistro/{lib64,lib} onto /lib64 and /lib;
# the loader then resolves the dynamic binary's interpreter +
# library through that namespace bind.
ldso_data = Path(sys.argv[1]).resolve().read_bytes()
print(f"  injecting /var/lib/distros/dyndistro/lib64/"
      f"ld-linux-x86-64.so.2 ({len(ldso_data)} bytes)")
archive += bi.cpio_entry(
    "/var/lib/distros/dyndistro/lib64/ld-linux-x86-64.so.2", ldso_data)

libc_data = Path(sys.argv[2]).resolve().read_bytes()
print(f"  injecting /var/lib/distros/dyndistro/lib/"
      f"x86_64-linux-gnu/libc.so.6 ({len(libc_data)} bytes)")
archive += bi.cpio_entry(
    "/var/lib/distros/dyndistro/lib/x86_64-linux-gnu/libc.so.6",
    libc_data)

archive += trailer
dest = here / "fs" / "initramfs_blob.S"
bi.emit_asm(archive, dest)
print(f"  rewrote {dest} (+dyndistro ld.so +libc.so.6, "
      f"total {len(archive)} bytes)")
PYEOF

echo "[test_u43_dynamic_namespace] (4/5) Rebuild kernel image"
mkdir -p build
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

echo "[test_u43_dynamic_namespace] (5/5) Boot QEMU + run via distrorun"
LOG=$(mktemp)
# Restore the baseline default initramfs on exit so subsequent tests
# (and a clean repo state) don't carry forward the +dyndistro form.
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null' EXIT

set +e
(
    sleep 3
    printf '/bin/distrorun dyndistro /bin/u_dynamic_ns_hello\n'
    sleep 6
    printf 'exit\n'
    sleep 1
) | timeout 40s qemu-system-x86_64 \
    -kernel "$ELF" \
    -smp 2 \
    -nographic \
    -no-reboot \
    -m 512M \
    -monitor none \
    -serial stdio \
    > "$LOG" 2>&1
rc=$?
set -e

echo "[test_u43_dynamic_namespace] --- captured output ---"
cat "$LOG"
echo "[test_u43_dynamic_namespace] --- end output ---"

fail=0

# 1. distrorun privatised the namespace and grafted /lib64 + /lib.
if grep -F -q "[distrorun] entered namespace ok" "$LOG"; then
    echo "[test_u43_dynamic_namespace] OK: distrorun entered namespace"
else
    echo "[test_u43_dynamic_namespace] MISS: distrorun never reached exec"
    fail=1
fi

# 2. The loader detected PT_INTERP — the dynamic-ELF arm fired.
if grep -F -q "PT_INTERP=" "$LOG"; then
    echo "[test_u43_dynamic_namespace] OK: loader detected PT_INTERP"
else
    echo "[test_u43_dynamic_namespace] MISS: no PT_INTERP detect printk"
    fail=1
fi

# 3. The interpreter was loaded — recursive ELF load completed. This
#    proves ns_blob_ptr resolved "/lib64/ld-linux-x86-64.so.2" through
#    the distrorun bind to the distro tree's ld.so (the interpreter
#    is NOT staged at the global /lib64 path — only inside the
#    dyndistro backing — so a load here means the namespace lookup
#    worked).
if grep -F -q "dynamic load: interp_base=" "$LOG"; then
    echo "[test_u43_dynamic_namespace] OK: interpreter resolved via namespace"
else
    echo "[test_u43_dynamic_namespace] MISS: interpreter not loaded" \
         "(namespace PT_INTERP lookup failed)"
    fail=1
fi

# 4. PRIMARY: the application's main() ran. ld.so walked the app's
#    PT_DYNAMIC, resolved DT_NEEDED=[libc.so.6] through the namespace
#    bind, relocated everything, and jumped to main().
if grep -F -q "U43 dynamic-ns hello" "$LOG"; then
    echo "[test_u43_dynamic_namespace] OK: dynamic binary reached main()" \
         "inside namespace"
else
    echo "[test_u43_dynamic_namespace] MISS: 'U43 dynamic-ns hello'" \
         "did not land on serial"
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_u43_dynamic_namespace] FAIL (qemu rc=$rc):" \
         "dynamic ELF did not run inside the namespace"
    exit 1
fi

echo "[test_u43_dynamic_namespace] PASS — dynamic Linux binary ran" \
     "inside a distro-shaped namespace!"
exit 0
