#!/usr/bin/env bash
# scripts/test_mmap.sh - demand-paging mmap/munmap/mprotect regression (§142).
#
# Drives tests/test_mmap.ad, which:
#   T1. Anonymous single-page mmap: write + read sentinel (1 demand fault).
#   T2. Multi-page mmap: write unique values per page (4 demand faults).
#   T3. mprotect: change protection flags, verify 0 return.
#   T4. munmap: unmap both regions, verify 0 return.
#
# Pipeline:
#   1. Build all userland binaries (hamsh + helpers).
#   2. Build tests/test_mmap.ad -> build/user/test_mmap.elf.
#   3. /init = hamsh.elf so we land at a shell prompt.
#   4. Rebuild the kernel image.
#   5. Boot QEMU, run /bin/test_mmap via hamsh, collect serial log.
#   6. Grep the log for per-test and final PASS banners.
#
# PASS = serial log contains all of:
#   [mmap] T1 PASS
#   [mmap] T2 PASS
#   [mmap] T3 PASS
#   [mmap] T4 PASS
#   [mmap] PASS
# and no "[mmap] FAIL" line.

. "$(dirname "$0")/_build_lock.sh"
. "$(dirname "$0")/_qemu_drive.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf
TEST_ELF=build/user/test_mmap.elf

echo "[test_mmap] (1/5) Build userland (hamsh + helpers)"
bash scripts/build_user.sh >/dev/null
bash scripts/build_modules.sh >/dev/null

echo "[test_mmap] (2/5) Build tests/test_mmap.ad -> $TEST_ELF"
python3 -m compiler.adder compile \
    --target=x86_64-adder-user \
    tests/test_mmap.ad \
    -o "$TEST_ELF" >/dev/null

echo "[test_mmap] (3/5) Plant /init = hamsh + /bin/test_mmap in cpio"
INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py >/dev/null

echo "[test_mmap] (4/5) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

echo "[test_mmap] (5/5) Boot QEMU + drive the test via hamsh"
LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null' EXIT

set +e
qemu_drive "$LOG" "$ELF" "[hamsh] M16.35 shell ready" 90 \
    -- "/bin/test_mmap" 30 \
       "exit" 1
rc="$QEMU_DRIVE_RC"
set -e

echo "[test_mmap] --- captured output ---"
cat "$LOG"
echo "[test_mmap] --- end output ---"

fail=0

# Check per-test PASS banners.
for t in 1 2 3 4; do
    if grep -F -q "[mmap] T${t} PASS" "$LOG"; then
        echo "[test_mmap] OK: T${t} passed"
    else
        echo "[test_mmap] MISS: T${t} PASS banner absent"
        fail=1
    fi
done

# A FAIL line is a hard failure.
if grep -F -q "[mmap] FAIL" "$LOG"; then
    echo "[test_mmap] FAIL: fixture reported a failure"
    grep -F "[mmap] FAIL" "$LOG" || true
    fail=1
fi

# Final PASS banner.
if grep -F -q "[mmap] PASS" "$LOG"; then
    echo "[test_mmap] OK: fixture reached final PASS"
else
    echo "[test_mmap] MISS: final PASS banner absent"
    fail=1
fi

# Kernel exception diagnostics.
if grep -F -q "[trap-diag] vec=" "$LOG"; then
    echo "[test_mmap] DIAG: kernel reported a CPU exception"
    grep -F "[trap-diag] vec=" "$LOG" | head -6 || true
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_mmap] FAIL (qemu rc=$rc)"
    exit 1
fi

echo "[test_mmap] PASS -- demand-paging mmap/munmap/mprotect working"
