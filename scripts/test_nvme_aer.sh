#!/usr/bin/env bash
# scripts/test_nvme_aer.sh — verify the native NVMe driver
# (drivers/nvme/nvme.ad) async-event / abort / reset-recovery maturity:
#
#   * Asynchronous Event Request (admin opcode 0x0C): the driver parks
#     AERL+1 AERs in the controller at init so it can report async events,
#     decodes any AER completion (event type/info/log-page), reads the
#     indicated log to clear the event, and refills the AER queue.
#   * Abort (admin opcode 0x08): an Abort targeting a specific SQID/CID
#     round-trips to the controller.
#   * Command timeout + controller reset recovery: an admin command with a
#     deliberately tiny poll budget times out, escalates to an Abort, then
#     performs a REAL controller disable->enable reset dance (re-creating
#     the admin + I/O queues) and the controller comes back usable
#     (post-reset IDENTIFY + I/O read of LBA 0 both succeed).
#
# Boots QEMU once with a single NVMe controller + one namespace (with an
# MBR signature at LBA 0 so the existing nvme_smoke_test LBA-0 grep keeps
# passing). The driver's nvme_smoke_test() runs at boot and, after the
# established IDENTIFY / queue-creation / health self-test, runs the new
# _nvme_aer_self_test().
#
# PASS markers grepped below (all emitted by drivers/nvme/nvme.ad):
#   "[nvme-aer] PASS aer-submit"
#   "[nvme-aer] PASS abort"
#   "[nvme-aer] PASS reset-recovery"
#   "[nvme-aer] PASS"
#
# Any "[nvme-aer] ... FAIL" banner is a hard fail.
#
# Build lock: source `_build_lock.sh` ONCE here (build_user /
# build_modules / build_initramfs each take the same lock).

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf

echo "[test_nvme_aer] (1/4) Build userland + modules + initramfs"
if [ ! -f build/user/init.elf ]; then
    bash scripts/build_user.sh >/dev/null
    bash scripts/build_modules.sh >/dev/null
fi
INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null

echo "[test_nvme_aer] (2/4) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

echo "[test_nvme_aer] (3/4) Mint a 1 MiB disk for the NVMe namespace"
NS1_DISK=$(mktemp --suffix=.nvme-aer-ns1)
dd if=/dev/zero of="$NS1_DISK" bs=1M count=1 status=none
# MBR signature on nsid=1 LBA 0 so nvme_smoke_test's LBA-0 grep passes.
printf '\x55\xaa' | dd of="$NS1_DISK" bs=1 seek=510 conv=notrunc status=none

LOG=$(mktemp)
trap 'rm -f "$LOG" "$NS1_DISK"' EXIT

echo "[test_nvme_aer] (4/4) Boot QEMU: 1 NVMe controller, 1 namespace"
set +e
timeout 30s qemu-system-x86_64 \
    -kernel "$ELF" \
    -device nvme,id=nvme0,serial=hamnixaer,max_ioqpairs=4 \
    -drive id=nsa,file="$NS1_DISK",if=none,format=raw \
    -device nvme-ns,drive=nsa,nsid=1,bus=nvme0 \
    -nographic -no-reboot -m 256M -monitor none -serial stdio \
    > "$LOG" 2>&1 < /dev/null
rc=$?
set -e

echo "[test_nvme_aer] --- captured (nvme / nvme-aer / nvme-reset lines) ---"
grep -E '\[nvme\]|\[nvme-aer\]|\[nvme-reset\]' "$LOG" || true
echo "[test_nvme_aer] --- end ---"

# Panic / trap is unambiguously a regression.
if grep -aE -q "PANIC|panic:|TRAP:|BUG:" "$LOG"; then
    echo "[test_nvme_aer] FAIL: kernel panic / trap"
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
        echo "[test_nvme_aer] OK: '$needle'"
    else
        echo "[test_nvme_aer] MISS: '$needle'"
        fail=1
    fi
done

# New AER / abort / reset-recovery PASS markers.
for needle in \
    "[nvme-aer] PASS aer-submit" \
    "[nvme-aer] PASS abort" \
    "[nvme-reset] controller ready again" \
    "[nvme-aer] PASS reset-recovery" \
    "[nvme-aer] PASS"
do
    if grep -F -q "$needle" "$LOG"; then
        echo "[test_nvme_aer] OK: '$needle'"
    else
        echo "[test_nvme_aer] MISS: '$needle'"
        fail=1
    fi
done

# Hard-fail on any self-test failure banner.
for bad in \
    "[nvme-aer] FAIL: no AER outstanding after refill" \
    "[nvme-aer] FAIL: admin cmd wedged with AERs parked" \
    "[nvme-aer] FAIL: abort did not round-trip" \
    "[nvme-aer] FAIL: abort_count did not advance" \
    "[nvme-aer] FAIL: reset recovery never fired" \
    "[nvme-aer] FAIL: IDENTIFY after reset" \
    "[nvme-aer] FAIL: I/O read after reset"
do
    if grep -F -q "$bad" "$LOG"; then
        echo "[test_nvme_aer] FAIL: '$bad'"
        fail=1
    fi
done

if [ "$fail" -ne 0 ]; then
    echo "[test_nvme_aer] FAIL (qemu rc=$rc)"
    echo "[test_nvme_aer] --- full log tail ---"
    tail -n 80 "$LOG"
    exit 1
fi

echo "[test_nvme_aer] PASS"
