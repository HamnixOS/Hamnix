#!/usr/bin/env bash
# scripts/test_net_irq.sh — verify the M16.112 IOAPIC + virtio-net
# IRQ path lands on the wire alongside the existing polled path.
#
# Today's bare-metal kernel polls every device because the IOAPIC
# wasn't programmed; M16.112 fixes that for virtio-net. The driver
# now:
#   1. Reads PCI INTERRUPT_PIN / INTERRUPT_LINE from config space.
#   2. Programs IOAPIC redirection entry for that pin to deliver
#      CPU vector 0x40 to LAPIC id 0.
#   3. Registers `virtio_net_irq_handler` for vector 0x40 in the
#      irq_handlers[] table.
# The existing virtio_net_poll() loop in net_smoke_test stays —
# it's the safety net before sti enables interrupts.
#
# The test asserts (in addition to the test_net_virtio regression):
#   1. "[ioapic] id="                     → IOAPIC bring-up logged
#   2. "[virtio-net] PCI INTx pin="       → PCI config-space read
#   3. "[irq] handler registered for vector 0x40"
#                                         → handler table populated
#   4. "[ioapic] redirect pin="           → redirection entry written
#                                            ("vec=0x40" baked in)
#   5. "[virtio-net] RX packet: len="     → polled RX still works
#
# The polled-path assertion (#5) is critical: the IRQ wiring must
# not break the existing safety net. If it does, the network stack
# silently loses RX on any platform where IRQs don't fire (e.g.
# every CI run today, since SLIRP doesn't push unsolicited frames
# AFTER sti).

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-vmlinux.elf

echo "[test_net_irq] (1/3) Build userland + modules + initramfs"
bash scripts/build_user.sh >/dev/null
bash scripts/build_modules.sh >/dev/null
INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null

echo "[test_net_irq] (2/3) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

echo "[test_net_irq] (3/3) Boot QEMU with virtio-net + IOAPIC visible"
LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null' EXIT

set +e
timeout 20s qemu-system-x86_64 \
    -kernel "$ELF" \
    -netdev user,id=n0 \
    -device virtio-net-pci,netdev=n0,mac=52:54:00:12:34:56 \
    -nographic -no-reboot -m 256M -monitor none -serial stdio \
    > "$LOG" 2>&1 < /dev/null
rc=$?
set -e

echo "[test_net_irq] --- captured (ioapic / irq / virtio-net) ---"
grep -E '\[ioapic\]|\[irq\]|\[virtio-net\]' "$LOG" || true
echo "[test_net_irq] --- end ---"

fail=0
for needle in \
    "[ioapic] id=" \
    "[virtio-net] PCI INTx pin=" \
    "[irq] handler registered for vector 0x40" \
    "[ioapic] redirect pin=" \
    "[virtio-net] mac=52:54:00:12:34:56" \
    "[virtio-net] RX packet: len="
do
    if grep -F -q "$needle" "$LOG"; then
        echo "[test_net_irq] OK: '$needle'"
    else
        echo "[test_net_irq] MISS: '$needle'"
        fail=1
    fi
done

# Also assert the redirect carried vector 0x40 (the IRQ vector we
# claimed for virtio-net). Looser grep than the per-needle loop so
# the printk format (printk2 %d/%x) can shift without breaking the
# assertion.
if grep -E -q '\[ioapic\] redirect pin=[0-9]+ vec=0x40' "$LOG"; then
    echo "[test_net_irq] OK: redirect targets vector 0x40"
else
    echo "[test_net_irq] MISS: redirect did NOT target vector 0x40"
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_net_irq] FAIL (qemu rc=$rc)"
    echo "[test_net_irq] --- full log ---"
    cat "$LOG"
    exit 1
fi

echo "[test_net_irq] PASS"
