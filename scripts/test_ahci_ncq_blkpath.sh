#!/usr/bin/env bash
# scripts/test_ahci_ncq_blkpath.sh — AHCI NCQ block-path test.
#
# Boots the kernel once with /etc/ahci-ncq-blk-test planted
# (ENABLE_AHCI_NCQ_BLK_TEST=1) and a QEMU ich9-ahci SATA disk attached.
# init/main.ad at boot:37.ncqb calls ahci_ncq_blkpath_selftest()
# (drivers/ata/ahci.ad), which PROVES the block-layer hot path routes
# through the new NCQ plumbing — NOT the legacy serialised slot-0 path:
#
#   * The block-layer wrappers (_ahci_read_sectors_blkop /
#     _ahci_write_sectors_blkop, dispatched via blk_read_sectors /
#     blk_write_sectors) feed ahci_read_sectors / ahci_write_sectors,
#     which on the active port now route through _ncq_block_rw_sync.
#   * _ncq_block_rw_sync allocates a fresh slot via _ncq_alloc_slot
#     (or sleeps on the allocator wait queue when all 32 are in flight),
#     submits REAL NCQ via _ncq_submit_fpdma — using READ FPDMA QUEUED
#     (0x60) / WRITE FPDMA QUEUED (0x61) with the SACT-then-CI tag-issue
#     ordering — and SLEEPS on a per-slot wait queue until the IRQ
#     completes it.
#   * ahci_irq_handler now sweeps PxCI / PxSACT against the per-slot
#     bookkeeping and wq_wake_one's the completed slots' waiters.
#
# Self-test asserts:
#   * multiple distinct slots used (allocator rotated — NOT slot-0 only),
#   * burst-snapshot CI|SACT shows simultaneous in-flight queued commands
#     (peak in-flight > 1) OR IRQ-completion counter advanced,
#   * each slot's bytes match the legacy verify-read oracle,
#   * a real blk_read_sectors(sd0, lba=0) succeeds (proving block-layer
#     dispatch landed on the NCQ path).
#
# Pass marker:  [ahci-ncq-blk] PASS
# Fail marker:  [ahci-ncq-blk] FAIL / self-test reported FAIL

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

export HAMNIX_BUILD_LOCK_TIMEOUT="${HAMNIX_BUILD_LOCK_TIMEOUT:-900}"

ELF=build/hamnix-kernel.elf

echo "[test_ahci_ncq_blkpath] (1/4) Build userland (init)"
bash scripts/build_user.sh >/dev/null

echo "[test_ahci_ncq_blkpath] (2/4) Build kernel with /etc/ahci-ncq-blk-test marker"
INIT_ELF=build/user/init.elf ENABLE_AHCI_NCQ_BLK_TEST=1 \
    python3 scripts/build_initramfs.py >/dev/null
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

echo "[test_ahci_ncq_blkpath] (3/4) Mint a SATA disk with deterministic LBAs"
DISK=$(mktemp --suffix=.ncqblk-disk)
dd if=/dev/zero of="$DISK" bs=1M count=1 status=none
python3 - "$DISK" <<'PY'
import sys
path = sys.argv[1]
with open(path, "r+b") as f:
    for lba in range(8):
        sector = bytes(((lba * 37 + b) & 0xFF) for b in range(512))
        f.seek(lba * 512)
        f.write(sector)
    # MBR signature so the earlier ahci_smoke_test passes its MBR check.
    f.seek(510)
    f.write(b"\x55\xaa")
PY

LOG=$(mktemp)
trap 'rm -f "$LOG" "$DISK"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1 || true' EXIT

echo "[test_ahci_ncq_blkpath] (4/4) Boot QEMU with -device ahci + -device ide-hd"
set +e
timeout 180s qemu-system-x86_64 \
    -kernel "$ELF" \
    -drive if=none,file="$DISK",format=raw,id=hd0 \
    -device ahci,id=ahci0 \
    -device ide-hd,drive=hd0,bus=ahci0.0 \
    -smp 1 \
    -nographic -no-reboot -m 256M -monitor none -serial stdio \
    > "$LOG" 2>&1 < /dev/null
rc=$?
set -e

echo "[test_ahci_ncq_blkpath] --- captured (ahci-ncq-blk lines) ---"
grep -E '\[ahci-ncq-blk\]' "$LOG" || true
echo "[test_ahci_ncq_blkpath] --- end ---"

fail=0

if [ "$rc" -ne 0 ] && [ "$rc" -ne 124 ]; then
    echo "[test_ahci_ncq_blkpath] FAIL: qemu exited rc=$rc" >&2
    fail=1
fi

if grep -qF "[ahci-ncq-blk] FAIL" "$LOG"; then
    echo "[test_ahci_ncq_blkpath] FAIL: self-test reported an internal failure" >&2
    fail=1
fi
if grep -qF "[ahci-ncq-blk] self-test reported FAIL" "$LOG"; then
    echo "[test_ahci_ncq_blkpath] FAIL: self-test returned non-zero" >&2
    fail=1
fi

check() {
    local label="$1" needle="$2"
    if grep -qF "$needle" "$LOG"; then
        echo "[test_ahci_ncq_blkpath] PASS: $label"
    else
        echo "[test_ahci_ncq_blkpath] FAIL: $label (expected '$needle')" >&2
        fail=1
    fi
}

check "self-test ran"             "[ahci-ncq-blk] self-test start"
check "FPDMA submits issued"      "[ahci-ncq-blk] FPDMA submitted req="
check "distinct slots reported"   "[ahci-ncq-blk] distinct slots used="
check "block-layer dispatch hit"  "[ahci-ncq-blk] block-layer dispatch reached NCQ path"
check "irq-completion telemetry"  "[ahci-ncq-blk] irq-completions delta="
check "data verified"             "[ahci-ncq-blk] req="
check "blkpath self-test PASS"    "[ahci-ncq-blk] PASS"

# Multi-slot assertion: peak in-flight reported >= 2 OR IRQ delta > 0
# (proving the IRQ-driven completion path fired). Either is real NCQ —
# multi-slot fan-out PLUS either real overlap or real IRQ-completion.
if grep -qE '\[ahci-ncq-blk\] burst snapshot: CI\|SACT mask=[^ ]+ live=[2-9]' "$LOG"; then
    echo "[test_ahci_ncq_blkpath] PASS: peak in-flight > 1 (real NCQ overlap)"
elif grep -qE '\[ahci-ncq-blk\] irq-completions delta=[1-9]' "$LOG"; then
    echo "[test_ahci_ncq_blkpath] PASS: IRQ-completion path advanced"
else
    echo "[test_ahci_ncq_blkpath] FAIL: neither real overlap nor IRQ-completion observed" >&2
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_ahci_ncq_blkpath] FAIL"
    exit 1
fi

echo "[test_ahci_ncq_blkpath] PASS — AHCI block-layer hot path routes through FPDMA QUEUED + IRQ completion, with multi-slot concurrency"
