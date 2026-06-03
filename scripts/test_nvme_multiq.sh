#!/usr/bin/env bash
# scripts/test_nvme_multiq.sh — verify the native NVMe driver
# (drivers/nvme/nvme.ad) matured to MULTI-I/O-QUEUE + MULTI-NAMESPACE.
#
# Boots QEMU once with a single NVMe controller that exposes:
#   * max_ioqpairs=4   — so SET FEATURES (Number of Queues) grants the
#     driver up to 4 I/O queue pairs (qid 1..4),
#   * TWO namespaces   — nsid=1 (with an MBR signature at LBA 0 so the
#     existing nvme_smoke_test LBA-0 grep keeps passing) and nsid=2.
#
# The hand-rolled driver's nvme_smoke_test() runs at boot (no
# /etc/nvme-io-ko marker), enumerates namespaces via IDENTIFY CNS=0x02,
# negotiates the queue count via SET FEATURES, creates N I/O queue
# pairs, registers each namespace as a block device, and runs
# _nvme_multiq_self_test() which:
#   * reports queues=N namespaces=M,
#   * pins a WRITE+READ round-trip to the HIGHEST I/O queue (qid=N) and
#     byte-compares (proves a second queue is independently functional),
#   * reads LBA 0 of the SECOND namespace over its own nsid.
#
# PASS markers grepped below (all emitted by drivers/nvme/nvme.ad):
#   "[nvme] namespaces active=2"        (or >=2)
#   "[nvme] I/O queues online (count="  with count >= 2
#   "[nvme-multiq] PASS multi-queue (>1 I/O queue)"
#   "[nvme-multiq] PASS multi-namespace (>1 NS)"
#   "[nvme-multiq] PASS second-queue read (qid="
#   "[nvme-multiq] PASS second-namespace read (nsid="
#
# A "[nvme-multiq] ... MISMATCH" or "... FAILED" banner is a hard fail.
#
# Build lock: source `_build_lock.sh` ONCE here (build_user /
# build_modules / build_initramfs each take the same lock).

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf

echo "[test_nvme_multiq] (1/4) Build userland + modules + initramfs"
if [ ! -f build/user/init.elf ]; then
    bash scripts/build_user.sh >/dev/null
    bash scripts/build_modules.sh >/dev/null
fi
INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null

echo "[test_nvme_multiq] (2/4) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

echo "[test_nvme_multiq] (3/4) Mint 1 MiB disks for two NVMe namespaces"
NS1_DISK=$(mktemp --suffix=.nvme-mq-ns1)
NS2_DISK=$(mktemp --suffix=.nvme-mq-ns2)
dd if=/dev/zero of="$NS1_DISK" bs=1M count=1 status=none
dd if=/dev/zero of="$NS2_DISK" bs=1M count=1 status=none
# MBR signature on nsid=1 LBA 0 so nvme_smoke_test's LBA-0 grep passes.
printf '\x55\xaa' | dd of="$NS1_DISK" bs=1 seek=510 conv=notrunc status=none
# Plant a recognisable marker at nsid=2 LBA 0 (not asserted byte-wise,
# but useful for eyeballing the log if the second-NS read regresses).
printf '\x55\xaa' | dd of="$NS2_DISK" bs=1 seek=510 conv=notrunc status=none

LOG=$(mktemp)
trap 'rm -f "$LOG" "$NS1_DISK" "$NS2_DISK"' EXIT

echo "[test_nvme_multiq] (4/4) Boot QEMU: 1 NVMe controller, 4 ioqpairs, 2 namespaces"
set +e
timeout 30s qemu-system-x86_64 \
    -kernel "$ELF" \
    -device nvme,id=nvme0,serial=hamnixmq,max_ioqpairs=4 \
    -drive id=nsa,file="$NS1_DISK",if=none,format=raw \
    -device nvme-ns,drive=nsa,nsid=1,bus=nvme0 \
    -drive id=nsb,file="$NS2_DISK",if=none,format=raw \
    -device nvme-ns,drive=nsb,nsid=2,bus=nvme0 \
    -nographic -no-reboot -m 256M -monitor none -serial stdio \
    > "$LOG" 2>&1 < /dev/null
rc=$?
set -e

echo "[test_nvme_multiq] --- captured (nvme / nvme-multiq lines) ---"
grep -E '\[nvme\]|\[nvme-multiq\]' "$LOG" || true
echo "[test_nvme_multiq] --- end ---"

# Panic / trap is unambiguously a regression.
if grep -aE -q "PANIC|panic:|TRAP:|BUG:" "$LOG"; then
    echo "[test_nvme_multiq] FAIL: kernel panic / trap"
    tail -n 60 "$LOG"
    exit 1
fi

fail=0

# Controller baseline must still come up + see the MBR signature on ns1.
for needle in \
    "[nvme] controller ready" \
    "[nvme] MBR signature OK"
do
    if grep -F -q "$needle" "$LOG"; then
        echo "[test_nvme_multiq] OK: '$needle'"
    else
        echo "[test_nvme_multiq] MISS: '$needle'"
        fail=1
    fi
done

# Multi-namespace enumeration: at least 2 active namespaces.
NS_LINE=$(grep -F "[nvme] namespaces active=" "$LOG" | tail -1 || true)
NS_COUNT=$(printf '%s' "$NS_LINE" | sed -n 's/.*namespaces active=\([0-9]\+\).*/\1/p')
NS_COUNT=${NS_COUNT:-0}
if [ "$NS_COUNT" -ge 2 ]; then
    echo "[test_nvme_multiq] OK: enumerated >1 namespace (active=$NS_COUNT)"
else
    echo "[test_nvme_multiq] MISS: expected >=2 namespaces, got '$NS_COUNT'"
    fail=1
fi

# Multi-queue creation: count >= 2 from the "I/O queues online" line.
Q_LINE=$(grep -F "[nvme] I/O queues online (count=" "$LOG" | tail -1 || true)
Q_COUNT=$(printf '%s' "$Q_LINE" | sed -n 's/.*count=\([0-9]\+\).*/\1/p')
Q_COUNT=${Q_COUNT:-0}
if [ "$Q_COUNT" -ge 2 ]; then
    echo "[test_nvme_multiq] OK: created >1 I/O queue (count=$Q_COUNT)"
else
    echo "[test_nvme_multiq] MISS: expected >=2 I/O queues, got '$Q_COUNT'"
    fail=1
fi

# Self-test PASS markers.
for needle in \
    "[nvme-multiq] PASS multi-queue (>1 I/O queue)" \
    "[nvme-multiq] PASS multi-namespace (>1 NS)" \
    "[nvme-multiq] PASS second-queue read (qid=" \
    "[nvme-multiq] PASS second-namespace read (nsid="
do
    if grep -F -q "$needle" "$LOG"; then
        echo "[test_nvme_multiq] OK: '$needle'"
    else
        echo "[test_nvme_multiq] MISS: '$needle'"
        fail=1
    fi
done

# Hard-fail on any self-test mismatch / failure banner.
if grep -F -q "[nvme-multiq] q2 MISMATCH" "$LOG"; then
    echo "[test_nvme_multiq] FAIL: second-queue readback MISMATCH"
    fail=1
fi
if grep -F -q "[nvme-multiq] second-namespace read FAILED" "$LOG"; then
    echo "[test_nvme_multiq] FAIL: second-namespace read FAILED"
    fail=1
fi
if grep -F -q "[nvme-multiq] q2 I/O failed" "$LOG"; then
    echo "[test_nvme_multiq] FAIL: second-queue I/O failed"
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_nvme_multiq] FAIL (qemu rc=$rc)"
    echo "[test_nvme_multiq] --- full log tail ---"
    tail -n 80 "$LOG"
    exit 1
fi

echo "[test_nvme_multiq] PASS"
