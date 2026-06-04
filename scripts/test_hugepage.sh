#!/usr/bin/env bash
# scripts/test_hugepage.sh - 2 MiB huge-page (MAP_HUGETLB) mmap regression.
#
# Drives tests/test_hugepage.ad, which:
#   T1. 4 MiB MAP_HUGETLB|MAP_ANONYMOUS region maps + base is 2MiB-aligned.
#   T2. Writes a per-4KiB-offset pattern spanning BOTH 2 MiB pages and
#       reads it back byte-identically (proves one 2 MiB PDE covers all
#       512 4 KiB sub-offsets within it).
#   T3. A second huge region with a distinct pattern; region 1 unchanged
#       (the two huge mappings are isolated).
#   T4. An unaligned length is rejected -EINVAL (hugetlbfs semantics).
#   T5. munmap both regions, verify 0.
#
# Pipeline:
#   1. Build all userland binaries (hamsh + helpers + test_hugepage).
#   2. Build tests/test_hugepage.ad -> build/user/test_hugepage.elf.
#   3. /init = hamsh.elf so we land at a shell prompt.
#   4. Rebuild the kernel image.
#   5. Boot QEMU, run /bin/test_hugepage via hamsh, collect serial log.
#   6. Grep the log for per-test and final PASS banners AND the kernel's
#      "[hugepage] installed 2MiB PS-bit PDE" proof line.
#
# PASS = serial log contains all of:
#   [hugepage] T1 PASS .. [hugepage] T5 PASS
#   [hugepage] PASS
#   [hugepage] installed 2MiB PS-bit PDE        (kernel-side PS-bit proof)
# and no "[hugepage] FAIL" line.

. "$(dirname "$0")/_build_lock.sh"
. "$(dirname "$0")/_qemu_drive.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf
TEST_ELF=build/user/test_hugepage.elf

echo "[test_hugepage] (1/5) Build userland (hamsh + helpers)"
bash scripts/build_user.sh >/dev/null
bash scripts/build_modules.sh >/dev/null

echo "[test_hugepage] (2/5) Build tests/test_hugepage.ad -> $TEST_ELF"
python3 -m compiler.adder compile \
    --target=x86_64-adder-user \
    tests/test_hugepage.ad \
    -o "$TEST_ELF" >/dev/null

echo "[test_hugepage] (3/5) Plant /init = hamsh + /bin/test_hugepage in cpio"
INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py >/dev/null

echo "[test_hugepage] (4/5) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

echo "[test_hugepage] (5/5) Boot QEMU + drive the test via hamsh"
LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null' EXIT

set +e
qemu_drive "$LOG" "$ELF" "[hamsh] M16.35 shell ready" 90 \
    -- "/bin/test_hugepage" 30 \
       "exit" 1
rc="$QEMU_DRIVE_RC"
set -e

echo "[test_hugepage] --- captured output ---"
cat "$LOG"
echo "[test_hugepage] --- end output ---"

fail=0

# Check per-test PASS banners.
for t in 1 2 3 4 5; do
    if grep -F -q "[hugepage] T${t} PASS" "$LOG"; then
        echo "[test_hugepage] OK: T${t} passed"
    else
        echo "[test_hugepage] MISS: T${t} PASS banner absent"
        fail=1
    fi
done

# A FAIL line is a hard failure.
if grep -F -q "[hugepage] FAIL" "$LOG"; then
    echo "[test_hugepage] FAIL: fixture reported a failure"
    grep -F "[hugepage] FAIL" "$LOG" || true
    fail=1
fi

# Final PASS banner.
if grep -F -q "[hugepage] PASS" "$LOG"; then
    echo "[test_hugepage] OK: fixture reached final PASS"
else
    echo "[test_hugepage] MISS: final PASS banner absent"
    fail=1
fi

# Kernel-side PROOF: a real 2 MiB PS-bit PDE was installed. This is the
# load-bearing assertion that the region used huge pages, NOT 512 4 KiB
# pages — the kernel prints this only from _vma_demand_fault_huge after a
# successful elf_map_one_huge_pde (PS=1) install.
if grep -F -q "[hugepage] installed 2MiB PS-bit PDE" "$LOG"; then
    cnt=$(grep -F -c "[hugepage] installed 2MiB PS-bit PDE" "$LOG" || true)
    echo "[test_hugepage] OK: kernel installed $cnt real 2 MiB PS-bit PDE(s)"
else
    echo "[test_hugepage] MISS: no kernel PS-bit PDE install line (huge page never used?)"
    fail=1
fi

# Kernel exception diagnostics.
if grep -F -q "[trap-diag] vec=" "$LOG"; then
    echo "[test_hugepage] DIAG: kernel reported a CPU exception"
    grep -F "[trap-diag] vec=" "$LOG" | head -6 || true
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_hugepage] FAIL (qemu rc=$rc)"
    exit 1
fi

echo "[test_hugepage] PASS -- 2 MiB MAP_HUGETLB mmap backed by real PS-bit PDEs"
