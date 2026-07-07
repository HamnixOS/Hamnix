#!/usr/bin/env bash
# scripts/test_bigmmap.sh — >4 GiB large-VMA zeroing regression at -m 6G.
#
# Deterministic, load-immune companion to the XWayland-at-6G repro for the
# _vma_alloc_large boot-CR3 zeroing fix. Drives tests/test_bigmmap.ad,
# which maps 4 MiB anonymous regions in a loop until it has committed +
# zeroed > 4 GiB of RAM. With the guest at -m 6G, chunks NECESSARILY land
# above the 4 GiB physical line; each is zeroed by the kernel under the
# boot cr3. Pre-fix the box HALTS on the first >4 GiB chunk's memset
# (kernel #PF, aliased VA absent under the task cr3); post-fix it climbs
# past 4 GiB and prints "[bigmmap] PASS".
#
# PASS = serial log contains "[bigmmap] PASS" and no "[bigmmap] FAIL" and
# no kernel "[trap-diag] vec=".
#
# Boots the native kernel via the GRUB-ISO -kernel shim under KVM at 6 GiB.

. "$(dirname "$0")/_build_lock.sh"
. "$(dirname "$0")/_qemu_drive.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf
TEST_ELF=build/user/test_bigmmap.elf

echo "[test_bigmmap] (1/5) Build userland (hamsh + helpers)"
bash scripts/build_user.sh >/dev/null
bash scripts/build_modules.sh >/dev/null

echo "[test_bigmmap] (2/5) Build tests/test_bigmmap.ad -> $TEST_ELF"
python3 -m compiler.adder compile \
    --target=x86_64-adder-user \
    tests/test_bigmmap.ad \
    -o "$TEST_ELF" >/dev/null

echo "[test_bigmmap] (3/5) Plant /init = hamsh + /bin/test_bigmmap in cpio"
INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py >/dev/null

echo "[test_bigmmap] (4/5) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

echo "[test_bigmmap] (5/5) Boot QEMU (-m 6G, KVM) + drive the test via hamsh"
LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null' EXIT

KVM_ARGS=""
if [ -e /dev/kvm ]; then
    KVM_ARGS="-enable-kvm -cpu host"
    echo "[test_bigmmap] using KVM."
else
    echo "[test_bigmmap] NOTE: /dev/kvm absent — running under TCG (slow)."
fi

set +e
HAMNIX_VM_MEM=6G QEMU_EXTRA_ARGS="$KVM_ARGS" \
qemu_drive "$LOG" "$ELF" "[hamsh] M16.35 shell ready" 240 \
    -- "/bin/test_bigmmap" 180 \
       "exit" 1
rc="$QEMU_DRIVE_RC"
set -e

echo "[test_bigmmap] --- captured output ---"
cat "$LOG"
echo "[test_bigmmap] --- end output ---"

fail=0
if grep -F -q "[bigmmap] PASS" "$LOG"; then
    echo "[test_bigmmap] OK: fixture reached PASS (>4 GiB chunks zeroed, no halt)"
else
    echo "[test_bigmmap] MISS: final PASS banner absent"
    fail=1
fi
if grep -F -q "[bigmmap] FAIL" "$LOG"; then
    echo "[test_bigmmap] FAIL: fixture reported a failure"
    grep -F "[bigmmap] FAIL" "$LOG" || true
    fail=1
fi
if grep -F -q "[trap-diag] vec=" "$LOG"; then
    echo "[test_bigmmap] DIAG: kernel reported a CPU exception (halt path)"
    grep -F "[trap-diag] vec=" "$LOG" | head -6 || true
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_bigmmap] FAIL (qemu rc=$rc)"
    exit 1
fi
echo "[test_bigmmap] PASS -- >4 GiB large-VMA zeroing works at -m 6G"
