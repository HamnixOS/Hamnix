#!/usr/bin/env bash
# scripts/test_nvme_health.sh — verify the native NVMe driver
# (drivers/nvme/nvme.ad) now issues the two commands that were
# previously dangling opcode constants:
#
#   * FLUSH                 (I/O opcode 0x00, NVME_IO_FLUSH)
#   * SMART/Health log page (admin opcode 0x02, NVME_ADMIN_GET_LOG,
#                            log id 0x02)
#
# Boots QEMU once with a single NVMe controller + one namespace (with an
# MBR signature at LBA 0 so the existing nvme_smoke_test LBA-0 grep keeps
# passing). The driver's nvme_smoke_test() runs at boot and, after the
# established IDENTIFY / queue-creation / multi-queue self-test, runs the
# new _nvme_health_self_test() which:
#   * writes a known pattern at LBA 4, FLUSHes nsid=1, and reads it back
#     to confirm the durability barrier completed (status 0) without
#     dropping data,
#   * fetches the SMART/Health log (GET LOG PAGE 0x02) and validates the
#     snapshot is present + self-consistent (temperature non-zero,
#     available-spare <= 100%).
#
# PASS markers grepped below (all emitted by drivers/nvme/nvme.ad):
#   "[nvme-health] PASS flush (nsid=1)"
#   "[nvme-health] PASS flush-durable readback"
#   "[nvme-health] PASS smart-log"
#
# Any "[nvme-health] ... FAILED" / "... MISMATCH" banner is a hard fail.
#
# Build lock: source `_build_lock.sh` ONCE here (build_user /
# build_modules / build_initramfs each take the same lock).

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf

echo "[test_nvme_health] (1/4) Build userland + modules + initramfs"
if [ ! -f build/user/init.elf ]; then
    bash scripts/build_user.sh >/dev/null
    bash scripts/build_modules.sh >/dev/null
fi
ENABLE_NVME_SELFTEST=1 INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null

echo "[test_nvme_health] (2/4) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

echo "[test_nvme_health] (3/4) Mint a 1 MiB disk for the NVMe namespace"
NS1_DISK=$(mktemp --suffix=.nvme-health-ns1)
dd if=/dev/zero of="$NS1_DISK" bs=1M count=1 status=none
# MBR signature on nsid=1 LBA 0 so nvme_smoke_test's LBA-0 grep passes.
printf '\x55\xaa' | dd of="$NS1_DISK" bs=1 seek=510 conv=notrunc status=none

LOG=$(mktemp)
trap 'rm -f "$LOG" "$NS1_DISK"' EXIT

echo "[test_nvme_health] (4/4) Boot QEMU: 1 NVMe controller, 1 namespace"
set +e
timeout 30s qemu-system-x86_64 \
    -kernel "$ELF" \
    -device nvme,id=nvme0,serial=hamnixhl,max_ioqpairs=4 \
    -drive id=nsa,file="$NS1_DISK",if=none,format=raw \
    -device nvme-ns,drive=nsa,nsid=1,bus=nvme0 \
    -nographic -no-reboot -m 256M -monitor none -serial stdio \
    > "$LOG" 2>&1 < /dev/null
rc=$?
set -e

echo "[test_nvme_health] --- captured (nvme / nvme-health lines) ---"
grep -E '\[nvme\]|\[nvme-health\]' "$LOG" || true
echo "[test_nvme_health] --- end ---"

# Panic / trap is unambiguously a regression.
if grep -aE -q "PANIC|panic:|TRAP:|BUG:" "$LOG"; then
    echo "[test_nvme_health] FAIL: kernel panic / trap"
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
        echo "[test_nvme_health] OK: '$needle'"
    else
        echo "[test_nvme_health] MISS: '$needle'"
        fail=1
    fi
done

# New self-test PASS markers.
for needle in \
    "[nvme-health] PASS flush (nsid=1)" \
    "[nvme-health] PASS flush-durable readback" \
    "[nvme-health] PASS smart-log"
do
    if grep -F -q "$needle" "$LOG"; then
        echo "[test_nvme_health] OK: '$needle'"
    else
        echo "[test_nvme_health] MISS: '$needle'"
        fail=1
    fi
done

# Hard-fail on any self-test failure / mismatch banner.
for bad in \
    "[nvme-health] FLUSH FAILED" \
    "[nvme-health] pre-flush write FAILED" \
    "[nvme-health] post-flush read FAILED" \
    "[nvme-health] post-flush MISMATCH" \
    "[nvme-health] SMART fetch FAILED" \
    "[nvme-health] SMART snapshot invalid"
do
    if grep -F -q "$bad" "$LOG"; then
        echo "[test_nvme_health] FAIL: '$bad'"
        fail=1
    fi
done

if [ "$fail" -ne 0 ]; then
    echo "[test_nvme_health] FAIL (qemu rc=$rc)"
    echo "[test_nvme_health] --- full log tail ---"
    tail -n 80 "$LOG"
    exit 1
fi

echo "[test_nvme_health] PASS"
