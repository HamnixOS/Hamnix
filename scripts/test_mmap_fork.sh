#!/usr/bin/env bash
# scripts/test_mmap_fork.sh — copy-on-write fork over an mmap VMA.
#
# Boots Hamnix with /bin/u_mmap_fork embedded and drives hamsh to exec
# it. u_mmap_fork is a host-built, static, OSABI=Linux x86_64 ELF that
# exercises the mmap-VMA copy-on-write path (mm/vma.ad::vma_fork_copy
# + the COW-aware free in _vma_node_free):
#
#   For each of 8 iterations: mmap a 2-page anonymous region, write a
#   parent sentinel into both pages, fork(). The child overwrites both
#   pages with a child sentinel and verifies it sees ONLY its own
#   value; the parent wait4()s, verifies its copy still holds the
#   parent sentinel, then munmap()s the region (a COW-shared free that
#   must route through cow_drop_page).
#
# PASS = the serial log shows "MF: start", a "MF: iter ok" per
# iteration, "MF: PASS", and NO "MF: FAIL" line / CPU trap.
#
# Build-on-missing: the fixture is gitignored (host-built). If absent,
# build it from tests/u-binary/src/mmap_fork; only SKIP on a real
# toolchain failure.

. "$(dirname "$0")/_build_lock.sh"
. "$(dirname "$0")/_qemu_drive.sh"
. "$(dirname "$0")/_ensure_ubin.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

UBIN=tests/u-binary/u_mmap_fork
ensure_ubin_or_skip test_mmap_fork u_mmap_fork mmap_fork

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf

echo "[test_mmap_fork] (1/4) Build userland (hamsh + helpers)"
bash scripts/build_user.sh
bash scripts/build_modules.sh

echo "[test_mmap_fork] (2/4) Swap /init = $HAMSH_ELF + embed u_mmap_fork"
HAMNIX_EMBED_UBIN=1 INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py

echo "[test_mmap_fork] (3/4) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF"

echo "[test_mmap_fork] (4/4) Boot QEMU + run /bin/u_mmap_fork via hamsh"
LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null' EXIT

set +e
qemu_drive "$LOG" "$ELF" "[hamsh] M16.35 shell ready" 60 \
    -- "u_mmap_fork" 20 \
       "exit" 1
rc="$QEMU_DRIVE_RC"
set -e

echo "[test_mmap_fork] --- captured output ---"
cat "$LOG"
echo "[test_mmap_fork] --- end output ---"

fail=0

if grep -F -q "MF: start" "$LOG"; then
    echo "[test_mmap_fork] OK: fixture ran"
else
    echo "[test_mmap_fork] MISS: fixture banner absent"
    fail=1
fi

# Every iteration must print "MF: iter ok" — a per-page refcount leak
# would OOM mmap on a later iteration, so a missing late iteration is
# the leak signature.
iters=8
ok_count=$(grep -F -c "MF: iter ok" "$LOG" || true)
if [ "$ok_count" -ge "$iters" ]; then
    echo "[test_mmap_fork] OK: all $iters iterations completed (iter ok x$ok_count)"
else
    echo "[test_mmap_fork] MISS: only $ok_count/$iters iterations completed (leak / OOM?)"
    fail=1
fi

# A FAIL line means COW leaked one side's write into the other, or an
# mmap / munmap returned an error.
if grep -F -q "MF: FAIL" "$LOG"; then
    echo "[test_mmap_fork] FAIL: fixture reported a COW / mmap failure"
    grep -F "MF: FAIL" "$LOG" || true
    fail=1
fi

if grep -F -q "MF: PASS" "$LOG"; then
    echo "[test_mmap_fork] OK: fixture reached PASS"
else
    echo "[test_mmap_fork] MISS: PASS banner absent"
    fail=1
fi

# A COW share OOM or a CPU exception is a hard failure — a double-free
# of a VMA page would corrupt the kernel and surface as a trap.
if grep -F -q "COW share OOM" "$LOG" || grep -F -q "vma copy OOM" "$LOG"; then
    echo "[test_mmap_fork] DIAG: kernel logged a fork COW/VMA OOM (page/refcount leak?)"
    fail=1
fi
if grep -F -q "[trap-diag] vec=" "$LOG"; then
    echo "[test_mmap_fork] DIAG: kernel reported a CPU exception"
    grep -F "[trap-diag] vec=" "$LOG" | head -6 || true
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_mmap_fork] FAIL (qemu rc=$rc)"
    exit 1
fi

echo "[test_mmap_fork] PASS -- copy-on-write fork over an mmap VMA keeps parent/child private"
