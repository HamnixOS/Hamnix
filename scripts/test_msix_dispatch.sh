#!/usr/bin/env bash
# scripts/test_msix_dispatch.sh — verify the L-shim multi-vector
# MSI-X allocator (linux_abi/api_pci.ad's pci_alloc_irq_vectors_
# affinity → api_irq.ad's MSI-X vector pool).
#
# This is the structural counterpart to test_msix.sh. That one
# verifies the NATIVE (hand-rolled drivers/net/virtio_net.ad) MSI-X
# delivery path; this one verifies the SHIM path that stock Linux
# .ko drivers (nvme, ahci-with-MSI-X, modern NICs) hit via the
# include/linux/pci.h surface.
#
# The kernel's msix_pool_smoke_test() (init/main.ad) walks PCI bus 0
# for an MSI-X-capable device, allocates 4 vectors via the new shim
# pci_alloc_irq_vectors_affinity, verifies each comes back as a
# distinct IDT vector in the 0x50..0x5F pool, and then frees.
# Boots with an MSI-X-capable target (-device nvme is the most
# convenient: 1b36:0010, MSI-X table_size = 16+; the smoke test
# caps at 4 by intent so the pool always has headroom for other
# devices in the test).
#
# Assertions:
#   1. "[msix-pool] using <vendor>:<device>" — bus walk found target
#   2. "[msix] allocated IDT vector 0x50"    — first pool vector
#   3. "[msix] allocated IDT vector 0x51"    — second pool vector
#   4. "[msix] allocated IDT vector 0x52"    — third pool vector
#   5. "[msix] allocated IDT vector 0x53"    — fourth pool vector
#   6. "[msix-pool] allocated 4 vectors"     — count check
#   7. "[msix-pool]   pci_irq_vector(0) -> 0x50"  — translation
#   8. "[msix-pool] alloc/free OK"           — clean teardown
#
# A clean run also leaves the previously-tested device in a sane
# state — _l_pci_free_irq_vectors_real disables MSI-X cap on the
# way out so any subsequent .ko probing the same device sees a
# fresh post-reset MSI-X state.

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf

echo "[test_msix_dispatch] (1/3) Build userland + modules + initramfs"
bash scripts/build_user.sh >/dev/null
bash scripts/build_modules.sh >/dev/null
INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null

echo "[test_msix_dispatch] (2/3) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

echo "[test_msix_dispatch] (3/3) Boot QEMU with MSI-X-capable nvme device"
LOG=$(mktemp)
DISK="$(mktemp --suffix=.img)"
truncate -s 16M "$DISK"
trap 'rm -f "$LOG" "$DISK"' EXIT

set +e
timeout 20s qemu-system-x86_64 \
    -kernel "$ELF" \
    -drive id=d0,file="$DISK",if=none,format=raw \
    -device nvme,drive=d0,serial=hamnix-msix-test-0 \
    -nographic -no-reboot -m 256M -monitor none -serial stdio \
    > "$LOG" 2>&1 < /dev/null
rc=$?
set -e

echo "[test_msix_dispatch] --- captured (msix-pool / msix / irq) ---"
grep -aE '\[msix-pool\]|\[msix\] allocated|\[irq\] handler registered for vector 0x5' "$LOG" || true
echo "[test_msix_dispatch] --- end ---"

fail=0
for needle in \
    "[msix-pool] using " \
    "[msix] allocated IDT vector 0x50" \
    "[msix] allocated IDT vector 0x51" \
    "[msix] allocated IDT vector 0x52" \
    "[msix] allocated IDT vector 0x53" \
    "[msix-pool] allocated 4 vectors" \
    "[msix-pool]   pci_irq_vector(0) -> 0x50" \
    "[msix-pool]   pci_irq_vector(1) -> 0x51" \
    "[msix-pool]   pci_irq_vector(2) -> 0x52" \
    "[msix-pool]   pci_irq_vector(3) -> 0x53" \
    "[msix-pool] alloc/free OK"
do
    if grep -F -q "$needle" "$LOG"; then
        echo "[test_msix_dispatch] OK: '$needle'"
    else
        echo "[test_msix_dispatch] MISS: '$needle'"
        fail=1
    fi
done

# A trap during the bus walk / cap-list dereference would be a hard
# failure — assert no CPU trap fired during the smoke test.
if grep -F -q "TRAP: vector" "$LOG"; then
    echo "[test_msix_dispatch] MISS: a CPU trap fired during the test"
    fail=1
else
    echo "[test_msix_dispatch] OK: no CPU trap fired"
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_msix_dispatch] FAIL (qemu rc=$rc)"
    echo "[test_msix_dispatch] --- full log tail ---"
    tail -n 120 "$LOG"
    exit 1
fi

echo "[test_msix_dispatch] PASS (4 MSI-X vectors allocated, each distinct, clean teardown)"
