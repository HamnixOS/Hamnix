#!/usr/bin/env bash
# scripts/test_vm_maturity.sh — §1 maturity of mprotect / madvise /
# MAP_FIXED.
#
# Boots Hamnix with /bin/u_vm_maturity embedded and drives hamsh to
# exec it. u_vm_maturity is a host-built, static, OSABI=Linux x86_64
# ELF that exercises the §1 item-4 work — mprotect / madvise(DONTNEED)
# / MAP_FIXED working for arbitrary callers, not just the loader's
# narrow patterns:
#
#   T1  mprotect over a SUB-RANGE: mmap 4 RW pages, mprotect the
#       middle 2 to PROT_READ then back to RW (drives vma_protect's
#       PTE re-walk + the VMA split), then write+read the whole
#       region — must round-trip.
#   T2  madvise(MADV_DONTNEED) DROPS pages: write a sentinel, advise
#       DONTNEED, read back — must be zero.
#   T3  MAP_FIXED REPLACES a mapping: mmap a region + write a
#       sentinel, then mmap MAP_FIXED at the same address — must land
#       exactly there and read back as fresh zero pages.
#
# PASS = the serial log shows "VM: start", "VM: T1 ok", "VM: T2 ok",
# "VM: T3 ok", "VM: PASS", and NO "VM: FAIL" line / CPU trap.
#
# Build-on-missing: the fixture is gitignored (host-built). If absent,
# build it from tests/u-binary/src/vm_maturity.

. "$(dirname "$0")/_build_lock.sh"
. "$(dirname "$0")/_qemu_drive.sh"
. "$(dirname "$0")/_ensure_ubin.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

UBIN=tests/u-binary/u_vm_maturity
ensure_ubin_or_skip test_vm_maturity u_vm_maturity vm_maturity

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf

echo "[test_vm_maturity] (1/4) Build userland (hamsh + helpers)"
bash scripts/build_user.sh
bash scripts/build_modules.sh

echo "[test_vm_maturity] (2/4) Swap /init = $HAMSH_ELF + embed u_vm_maturity"
HAMNIX_EMBED_UBIN=1 INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py

echo "[test_vm_maturity] (3/4) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF"

echo "[test_vm_maturity] (4/4) Boot QEMU + run /bin/u_vm_maturity via hamsh"
LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null' EXIT

set +e
qemu_drive "$LOG" "$ELF" "[hamsh] M16.35 shell ready" 60 \
    -- "u_vm_maturity" 10 \
       "exit" 1
rc="$QEMU_DRIVE_RC"
set -e

echo "[test_vm_maturity] --- captured output ---"
cat "$LOG"
echo "[test_vm_maturity] --- end output ---"

fail=0

if grep -F -q "VM: start" "$LOG"; then
    echo "[test_vm_maturity] OK: fixture ran"
else
    echo "[test_vm_maturity] MISS: fixture banner absent"
    fail=1
fi

for t in "T1 ok" "T2 ok" "T3 ok"; do
    if grep -F -q "VM: $t" "$LOG"; then
        echo "[test_vm_maturity] OK: VM: $t"
    else
        echo "[test_vm_maturity] MISS: VM: $t absent"
        fail=1
    fi
done

if grep -F -q "VM: FAIL" "$LOG"; then
    echo "[test_vm_maturity] FAIL: fixture reported a failure"
    grep -F "VM: FAIL" "$LOG" || true
    fail=1
fi

if grep -F -q "VM: PASS" "$LOG"; then
    echo "[test_vm_maturity] OK: fixture reached PASS"
else
    echo "[test_vm_maturity] MISS: PASS banner absent"
    fail=1
fi

if grep -F -q "[trap-diag] vec=" "$LOG"; then
    echo "[test_vm_maturity] DIAG: kernel reported a CPU exception"
    grep -F "[trap-diag] vec=" "$LOG" | head -6 || true
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_vm_maturity] FAIL (qemu rc=$rc)"
    exit 1
fi

echo "[test_vm_maturity] PASS -- mprotect / madvise(DONTNEED) / MAP_FIXED all mature"
