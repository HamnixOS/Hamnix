#!/usr/bin/env bash
# scripts/test_nvme_mq.sh — per-CPU multi-queue NVMe + multi-namespace gate.
#
# This script complements test_nvme_multiq.sh (which proves N>1 I/O
# queues + N>1 namespaces are wired) by additionally asserting:
#
#   * the I/O-queue picker is PER-CPU affine — the same CPU returns the
#     same qid every call (no RR drift), and the qid lies in
#     [1 .. n_io_queues],
#   * BOTH namespaces are independently reachable via their NSID at
#     the block layer (concurrent multi-NS I/O completes cleanly),
#   * the controller exposes nvme0n1 AND nvme0n2 as distinct block
#     devices ("[nvme] nvme0n1 registered" + "[nvme] nvme0n2 registered").
#
# QEMU config:
#   -drive id=nsa,file=...,if=none,format=raw
#   -device nvme,id=nvme0,serial=hamnixmq,max_ioqpairs=4
#   -device nvme-ns,drive=nsa,nsid=1,bus=nvme0
#   -drive id=nsb,file=...,if=none,format=raw
#   -device nvme-ns,drive=nsb,nsid=2,bus=nvme0
#
# (max_ioqpairs=4 = the controller hands the driver 4 I/O queue
# pairs, so the per-CPU picker has more than one queue to choose
# from. namespaces=2 via two `nvme-ns` devices because QEMU's
# `nvme,namespaces=N` shorthand only auto-creates EMPTY namespaces —
# we want backed disks so we can read LBA 0 of nsid=2.)

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf

echo "[test_nvme_mq] (1/4) Build userland + modules + initramfs"
if [ ! -f build/user/init.elf ]; then
    bash scripts/build_user.sh >/dev/null
    bash scripts/build_modules.sh >/dev/null
fi
ENABLE_NVME_SELFTEST=1 INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null

echo "[test_nvme_mq] (2/4) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

echo "[test_nvme_mq] (3/4) Mint 1 MiB disks for two NVMe namespaces"
NS1_DISK=$(mktemp --suffix=.nvme-mq-ns1)
NS2_DISK=$(mktemp --suffix=.nvme-mq-ns2)
dd if=/dev/zero of="$NS1_DISK" bs=1M count=1 status=none
dd if=/dev/zero of="$NS2_DISK" bs=1M count=1 status=none
# MBR signature on nsid=1 LBA 0 so the existing LBA-0 grep passes.
printf '\x55\xaa' | dd of="$NS1_DISK" bs=1 seek=510 conv=notrunc status=none
printf '\x55\xaa' | dd of="$NS2_DISK" bs=1 seek=510 conv=notrunc status=none

LOG=$(mktemp)
trap 'rm -f "$LOG" "$NS1_DISK" "$NS2_DISK"' EXIT

retry=0
boot_qemu() {
    set +e
    timeout 30s qemu-system-x86_64 \
        -kernel "$ELF" \
        -smp 2 \
        -device nvme,id=nvme0,serial=hamnixmq,max_ioqpairs=4 \
        -drive id=nsa,file="$NS1_DISK",if=none,format=raw \
        -device nvme-ns,drive=nsa,nsid=1,bus=nvme0 \
        -drive id=nsb,file="$NS2_DISK",if=none,format=raw \
        -device nvme-ns,drive=nsb,nsid=2,bus=nvme0 \
        -nographic -no-reboot -m 256M -monitor none -serial stdio \
        > "$LOG" 2>&1 < /dev/null
    rc=$?
    set -e
}

echo "[test_nvme_mq] (4/4) Boot QEMU: -smp 2, 4 ioqpairs, 2 namespaces"
boot_qemu

# 0-ticks-stage-07 heartbeat is inconclusive — retry ONCE.
if grep -F -q "0-ticks-stage-07-reached" "$LOG"; then
    echo "[test_nvme_mq] heartbeat inconclusive — retrying once"
    boot_qemu
    retry=1
fi

echo "[test_nvme_mq] --- captured (nvme / nvme-multiq lines) ---"
grep -E '\[nvme\]|\[nvme-multiq\]' "$LOG" || true
echo "[test_nvme_mq] --- end ---"

if grep -aE -q "PANIC|panic:|TRAP:|BUG:" "$LOG"; then
    echo "[test_nvme_mq] FAIL: kernel panic / trap"
    tail -n 60 "$LOG"
    exit 1
fi

fail=0

for needle in \
    "[nvme] controller ready" \
    "[nvme] MBR signature OK" \
    "[nvme] nvme0n2 registered"
do
    if grep -F -q "$needle" "$LOG"; then
        echo "[test_nvme_mq] OK: '$needle'"
    else
        echo "[test_nvme_mq] MISS: '$needle'"
        fail=1
    fi
done

# nvme0n1 is the primary NS — currently registered with a different
# "[nvme] registered as block slot=N (nvme0n1)" marker; tolerate
# either spelling.
if grep -E -q '\[nvme\] (nvme0n1 registered|registered as block slot=[0-9]+ \(nvme0n1\))' "$LOG"; then
    echo "[test_nvme_mq] OK: 'nvme0n1 registered (either marker)'"
else
    echo "[test_nvme_mq] MISS: 'nvme0n1 registered'"
    fail=1
fi

# Multi-namespace enumeration: at least 2 active namespaces.
NS_LINE=$(grep -F "[nvme] namespaces active=" "$LOG" | tail -1 || true)
NS_COUNT=$(printf '%s' "$NS_LINE" | sed -n 's/.*namespaces active=\([0-9]\+\).*/\1/p')
NS_COUNT=${NS_COUNT:-0}
if [ "$NS_COUNT" -ge 2 ]; then
    echo "[test_nvme_mq] OK: enumerated >1 namespace (active=$NS_COUNT)"
else
    echo "[test_nvme_mq] MISS: expected >=2 namespaces, got '$NS_COUNT'"
    fail=1
fi

# Multi-queue depth: >= 2 I/O queues.
Q_LINE=$(grep -F "[nvme] I/O queues online (count=" "$LOG" | tail -1 || true)
Q_COUNT=$(printf '%s' "$Q_LINE" | sed -n 's/.*count=\([0-9]\+\).*/\1/p')
Q_COUNT=${Q_COUNT:-0}
if [ "$Q_COUNT" -ge 2 ]; then
    echo "[test_nvme_mq] OK: created >1 I/O queue (count=$Q_COUNT)"
else
    echo "[test_nvme_mq] MISS: expected >=2 I/O queues, got '$Q_COUNT'"
    fail=1
fi

# Per-CPU picker + concurrent multi-NS PASS markers.
for needle in \
    "[nvme-multiq] PASS multi-queue (>1 I/O queue)" \
    "[nvme-multiq] PASS multi-namespace (>1 NS)" \
    "[nvme-multiq] PASS per-cpu picker" \
    "[nvme-multiq] PASS concurrent multi-ns I/O"
do
    if grep -F -q "$needle" "$LOG"; then
        echo "[test_nvme_mq] OK: '$needle'"
    else
        echo "[test_nvme_mq] MISS: '$needle'"
        fail=1
    fi
done

if grep -F -q "[nvme-multiq] per-cpu picker FAIL" "$LOG"; then
    echo "[test_nvme_mq] FAIL: per-cpu picker returned bad qid or drifted"
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_nvme_mq] FAIL (qemu rc=${rc:-?} retry=$retry)"
    echo "[test_nvme_mq] --- full log tail ---"
    tail -n 80 "$LOG"
    exit 1
fi

echo "[test_nvme_mq] PASS (retry=$retry)"
