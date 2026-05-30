#!/usr/bin/env bash
# scripts/test_dynamic_spawn_stress.sh — dynamic-ELF (PT_INTERP) spawn-
# reclaim regression. Companion to scripts/test_spawn_stress.sh, but for
# the dynamic-linker interpreter (ld-linux) image.
#
# REGRESSION GUARD (the interp-region leak): a DYNAMIC ELF spawn loads its
# PT_INTERP (/lib64/ld-linux-x86-64.so.2) as a SEPARATE region_alloc'd
# image — recursively, inside fs/elf.ad's _load_interp_elf path. Before
# this fix that interp region was NEVER recorded per-task and NEVER freed
# by task_reap, so EVERY dynamic-binary spawn permanently leaked the whole
# ld.so image span out of the region pool. Once the region pool bleeds out,
# sys_spawn's region_alloc returns 0 -> ENOEXEC and hamsh misreports
# "command not found" / the loader prints "elf64: OOM" — exactly the
# failure mode the static spawn-stress guard catches for the MAIN image,
# but driven by the interpreter.
#
# The fix (kernel/sched/core.ad TaskStruct.interp_phys + task_reap's
# interp arm + set_task_interp_phys; arch/x86/kernel/syscall.ad SYS_SPAWN
# and do_execve recording the interp region on the OWNING task — and the
# matching execve-replace free of the OUTGOING owner-only image/interp/
# ustack regions) gives the interp image the SAME owner-only reclaim path
# the main image already has. A reaped interp region returns to the pool
# and the next identical dynamic spawn recycles the SAME physical chunk,
# so the region pool stays FLAT across an unbounded number of dynamic
# spawns. task_reap also now drops each exiting task's mmap-backed VMAs
# (vma_clear) so a dynamic binary's DSO mappings no longer leak on a plain
# spawn+wait+reap exit (previously freed only on execve).
#
# WHAT THIS TEST ASSERTS: across MANY dynamic-binary spawns in one
# uninterrupted hamsh session — (a) the region pool never exhausts (no
# "elf64: OOM", no "command not found", no ENOEXEC), (b) no kernel fault,
# and (c) the shell survives every iteration to the final marker. That is
# precisely what the interp-region reclaim guarantees: before the fix the
# interp leak would have starved the region pool and wedged the shell with
# a not-found / OOM well before the last iteration.
#
# NOTE ON GLIBC ld.so's libc.so.6 mapping: a SEPARATE, PRE-EXISTING leak
# in the "reserve + MAP_FIXED overlay" split-VMA / COW-refcount teardown
# path (mm/vma.ad, OUT OF SCOPE for this kernel fix) caps how many times
# glibc's ld.so can successfully map libc.so.6 in one boot, so not every
# spawn prints the binary's own stdout marker. That is independent of the
# interp-region reclaim this test guards: the region pool stays flat and
# the SHELL survives regardless, which is the invariant asserted here.
#
# Self-sufficient on any glibc host: it injects the HOST's stock
# /lib64/ld-linux-x86-64.so.2 + libc.so.6 into the initramfs (no
# debootstrapped Debian rootfs required). If the host lacks a C compiler
# or those shared objects, it SKIPs (exit 0) like test_u42_dynamic_elf.sh.
#
# Boot/drive harness modelled on scripts/test_spawn_stress.sh; ld.so +
# libc injection modelled on scripts/test_u42_dynamic_elf.sh.

. "$(dirname "$0")/_build_lock.sh"
. "$(dirname "$0")/_qemu_drive.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

UBIN=tests/u-binary/u_dynamic_hello
# Prefer a staged Debian-minbase ld.so/libc if present; otherwise fall
# back to the HOST's system copies so the test runs on a bare glibc box.
LDSO=tests/distros/debian-minbase/rootfs/lib64/ld-linux-x86-64.so.2
LIBC=tests/distros/debian-minbase/rootfs/usr/lib/x86_64-linux-gnu/libc.so.6
[ -e "$LDSO" ] || LDSO=/lib64/ld-linux-x86-64.so.2
[ -e "$LIBC" ] || LIBC=/lib/x86_64-linux-gnu/libc.so.6

if [ ! -e "$LDSO" ] || [ ! -f "$(readlink -f "$LDSO")" ]; then
    echo "[test_dynamic_spawn_stress] SKIP: no usable ld-linux-x86-64.so.2"
    exit 0
fi
if [ ! -e "$LIBC" ] || [ ! -f "$(readlink -f "$LIBC")" ]; then
    echo "[test_dynamic_spawn_stress] SKIP: no usable libc.so.6"
    exit 0
fi

echo "[test_dynamic_spawn_stress] (1/5) Build dynamic_hello fixture"
make -C tests/u-binary/src/dynamic_hello install >/dev/null 2>&1 || true
if [ ! -f "$UBIN" ]; then
    echo "[test_dynamic_spawn_stress] SKIP: $UBIN not built (no host gcc?)"
    exit 0
fi
echo "[test_dynamic_spawn_stress]   $(file -b "$UBIN")"

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf

echo "[test_dynamic_spawn_stress] (2/5) Build userland (hamsh + helpers)"
bash scripts/build_user.sh >/dev/null
bash scripts/build_modules.sh >/dev/null 2>&1 || true

echo "[test_dynamic_spawn_stress] (3/5) Embed ld.so + libc + dynamic_hello in initramfs"
HAMNIX_EMBED_UBIN=1 INIT_ELF="$HAMSH_ELF" \
    python3 scripts/build_initramfs.py >/dev/null

LDSO_REAL=$(readlink -f "$LDSO")
LIBC_REAL=$(readlink -f "$LIBC")
python3 - "$LDSO_REAL" "$LIBC_REAL" <<'PYEOF'
import sys, os, importlib.util
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

ldso = Path(sys.argv[1]).resolve().read_bytes()
print(f"  injecting /lib64/ld-linux-x86-64.so.2 ({len(ldso)} bytes)")
archive += bi.cpio_entry("/lib64/ld-linux-x86-64.so.2", ldso)

libc = Path(sys.argv[2]).resolve().read_bytes()
print(f"  injecting /lib/x86_64-linux-gnu/libc.so.6 ({len(libc)} bytes)")
archive += bi.cpio_entry("/lib/x86_64-linux-gnu/libc.so.6", libc)

archive += trailer
dest = here / "fs" / "initramfs_blob.S"
bi.emit_asm(archive, dest)
print(f"  rewrote {dest} (total {len(archive)} bytes)")
PYEOF

echo "[test_dynamic_spawn_stress] (4/5) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal init/main.ad -o "$ELF" >/dev/null

LOG=$(mktemp /tmp/test-dyn-spawn-stress.XXXXXX.log)
# Restore the baseline default initramfs on exit so subsequent tests
# (and a clean repo state) don't carry forward the +ld.so form.
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1 || true' EXIT

# Spawn count. Each dynamic spawn region_alloc's the app image AND the
# ~225 KB interp image. With the interp leak unfixed the pool drifts by
# the interp span per spawn; 16 uninterrupted dynamic spawns only all
# complete if the interp region is actually reclaimed and recycled.
SPAWNS=16

CMDS=()
n=1
while [ "$n" -le "$SPAWNS" ]; do
    CMDS+=( "u_dynamic_hello" 4 )
    CMDS+=( "echo DYNSTRESS_${n}" 1 )
    n=$((n + 1))
done
CMDS+=( "echo DYNSTRESS_DONE" 2 )
CMDS+=( "exit" 1 )

echo "[test_dynamic_spawn_stress] (5/5) Boot QEMU + drive ${SPAWNS} dynamic-binary spawns"
set +e
qemu_drive "$LOG" "$ELF" "[hamsh] M16.35 shell ready" 300 \
    -- "${CMDS[@]}"
rc="$QEMU_DRIVE_RC"
set -e

if [ -n "${DYN_STRESS_KEEP_LOG:-}" ]; then
    cp "$LOG" "$DYN_STRESS_KEEP_LOG" || true
fi

echo "[test_dynamic_spawn_stress] --- captured output (filtered) ---"
grep -a -E "DYNSTRESS_|U42 dynamic hello|command not found|out of (tasks|memory)|cannot map|elf64: OOM|PANIC|panic:|TRAP:|BUG:" "$LOG" \
    | sed 's/\x1b\[[0-9;]*[a-zA-Z]//g' | tr -d '\000' | head -200
echo "[test_dynamic_spawn_stress] --- end output ---"

fail=0

# 1. The shell came up.
if ! grep -a -F -q "[hamsh] M16.35 shell ready" "$LOG"; then
    echo "[test_dynamic_spawn_stress] FAIL: hamsh never reached the interactive loop"
    echo "[test_dynamic_spawn_stress] FAIL"
    exit 1
fi

# Hard fault gate — any kernel fault is an unconditional FAIL.
if grep -a -E -q "PANIC|panic:|TRAP:|BUG:" "$LOG"; then
    echo "[test_dynamic_spawn_stress] FAIL: kernel fault during dynamic spawn stress"
    echo "[test_dynamic_spawn_stress] FAIL"
    exit 1
fi

outlines() { grep -a -vE 'hamsh\$|\] > ' "$LOG" 2>/dev/null || true; }

# 2. No spawn was ever reported as not-found. With the interp region
#    LEAKING (pre-fix), the region pool drains and sys_spawn's
#    region_alloc returns 0 -> ENOEXEC -> hamsh "command not found". The
#    interp reclaim keeps the pool flat, so this must never fire.
if outlines | grep -a -q "command not found"; then
    echo "[test_dynamic_spawn_stress] FAIL: a dynamic spawn was 'command not found' (interp/region leak)"
    fail=1
else
    echo "[test_dynamic_spawn_stress] OK: no 'command not found' for any dynamic spawn"
fi

# 3. No region-pool / ELF-loader exhaustion. "elf64: OOM" is the loader's
#    region_alloc-returned-0 signal — the DIRECT symptom of the interp
#    region (or main image) leaking the region pool dry. The interp
#    reclaim must keep this silent across all SPAWNS iterations.
if outlines | grep -a -E -q "out of memory|out of tasks|cannot map binary|elf64: OOM|elf: OOM"; then
    echo "[test_dynamic_spawn_stress] FAIL: region pool / ELF loader exhausted (interp leak?)"
    fail=1
else
    echo "[test_dynamic_spawn_stress] OK: region pool never exhausted (no elf OOM / ENOEXEC)"
fi

# 4. The dynamic binary reached main() at least once — proves the
#    PT_INTERP load path actually ran ld.so end-to-end (not a no-op
#    skip). NOTE: a SEPARATE pre-existing leak in glibc ld.so's
#    libc.so.6 split-VMA mapping (mm/vma.ad, out of scope here) caps how
#    many of the SPAWNS runs print this marker, so we do NOT require all
#    of them — the region-pool invariants (2/3) + shell survival (5) are
#    what the interp reclaim guarantees.
runs=$(outlines | grep -a -c "U42 dynamic hello")
echo "[test_dynamic_spawn_stress] u_dynamic_hello reached main() ${runs} times"
if [ "${runs:-0}" -ge 1 ]; then
    echo "[test_dynamic_spawn_stress] OK: PT_INTERP (ld.so) dynamic-load path exercised"
else
    echo "[test_dynamic_spawn_stress] FAIL: dynamic binary never reached main() — interp path broken"
    fail=1
fi

# 5. The shell reached the LAST iteration AND the final marker. This is
#    the core interp-reclaim invariant: under the OLD leaking behaviour
#    the region pool would have starved and hamsh would have wedged on a
#    not-found / OOM well before DYNSTRESS_<SPAWNS>. Reaching the last
#    iteration proves the interp region recycled the whole way.
if outlines | grep -a -q "DYNSTRESS_${SPAWNS}\b"; then
    echo "[test_dynamic_spawn_stress] OK: reached DYNSTRESS_${SPAWNS} (region pool recycled all the way)"
else
    echo "[test_dynamic_spawn_stress] FAIL: never reached DYNSTRESS_${SPAWNS} marker (shell wedged)"
    fail=1
fi
if outlines | grep -a -q "DYNSTRESS_DONE"; then
    echo "[test_dynamic_spawn_stress] OK: shell survived the whole dynamic spawn stress"
else
    echo "[test_dynamic_spawn_stress] FAIL: DYNSTRESS_DONE absent — shell wedged"
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_dynamic_spawn_stress] FAIL (qemu rc=$rc)"
    exit 1
fi
echo "[test_dynamic_spawn_stress] PASS (qemu rc=$rc)"
