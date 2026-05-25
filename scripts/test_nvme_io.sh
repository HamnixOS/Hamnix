#!/usr/bin/env bash
# scripts/test_nvme_io.sh — storage L-shim EXERCISE test for NVMe.
#
# The companion `test_nvme_ko.sh` is a LOAD-only test: it asserts
# the Debian 6.1.0-32 nvme.ko binary's UND surface is closed by
# linux_abi/api_nvme.ad and that init_module / probe runs through
# the cold-path stubs. The hand-rolled drivers/nvme/nvme.ad
# claims the controller first; nvme0n1 in that test's output is
# real because the HAND-ROLLED driver registered it. The .ko shim
# is just probing against an already-enabled controller.
#
# This script is the EXERCISE: gate the hand-rolled NVMe driver
# OFF via /etc/nvme-io-ko, kmod_linux_load nvme.ko, then run
# nvme_io_exercise() in init/main.ad which tries to find a block
# device that the .ko-shim path produced and read /hello.txt off
# it through fs/ext4.ad.
#
# Critical difference from test_ahci_io.sh: NO BRIDGE. The AHCI
# exercise routes _ahc_ahci_host_activate back to the hand-rolled
# drivers/ata/ahci.ad bring-up so the L-shim "completes" what the
# Linux .ko's probe started. The NVMe exercise does NOT do that.
# If nvme.ko's UND-stub surface (api_nvme.ad's -ENODEV-returning
# nvme_submit_sync_cmd and friends) can't carry namespace scan,
# blk_mq_alloc_disk, and the I/O queue setup, that's a finding,
# not a thing to paper over.
#
# Expected outcome on the current shim:
#   * Hand-rolled SKIPPED marker fires.
#   * nvme.ko load + probe succeed (cold-path stubs, same as
#     test_nvme_ko.sh).
#   * nvme_io_exercise() emits [bridge=disabled] so the test
#     harness can definitively assert no fallback path is active.
#   * nvme_io_exercise() reports a SPECIFIC failure mode (most
#     likely "no NVMe block device registered" — because
#     nvme_submit_sync_cmd returns -ENODEV, namespace scan never
#     completes, blk_mq_alloc_disk + add_disk never run, no
#     gendisk lands in the block layer).
#
# That FAIL is informative output. A PASS would mean the L-shim
# alone carried real NVMe I/O end to end — a major milestone.
# Either way the test SCRIPT exits 0 only on PASS so CI is honest.
#
# The PASS / FAIL channel is the [nvme_io_test] marker line
# emitted from nvme_io_exercise(). [bridge=disabled] is always
# expected; its absence is itself a regression.

. "$(dirname "$0")/_build_lock.sh"

set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf

echo "[test_nvme_io] (1/5) Build userland + modules"
bash scripts/build_user.sh >/dev/null
bash scripts/build_modules.sh >/dev/null

echo "[test_nvme_io] (2/5) Build ext4 NVMe disk image with /hello.txt"
DISK="build/nvme-test.img"
mkdir -p build
bash scripts/_make_ext4_test_disk.sh "$DISK" "nvme-shim-works" >/dev/null

if [ ! -f "$DISK" ]; then
    echo "[test_nvme_io] FAIL: $DISK not generated (mkfs.ext4 missing?)"
    exit 1
fi

echo "[test_nvme_io] (3/5) Build initramfs with /etc/nvme-io-ko marker"
ENABLE_NVME_IO_TEST=1 INIT_ELF=build/user/init.elf \
    python3 scripts/build_initramfs.py >/dev/null

echo "[test_nvme_io] (4/5) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

LOG="$(mktemp)"
# Use a scratch copy of the ext4 image so the write-round-trip step
# inside nvme_io_exercise (LBA 1 pattern) doesn't mutate the source.
# Other future tests reading the same image stay reproducible.
SCRATCH_DISK="$(mktemp --suffix=.nvme-io.img)"
cp "$DISK" "$SCRATCH_DISK"
# Restore the default initramfs at the end so subsequent tests don't
# inherit ENABLE_NVME_IO_TEST state.
trap 'rm -f "$LOG" "$SCRATCH_DISK"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1 || true' EXIT

echo "[test_nvme_io] (5/5) Boot QEMU with -device nvme + scratch ext4 disk"
set +e
timeout 30s qemu-system-x86_64 \
    -kernel "$ELF" \
    -drive id=nvm,file="$SCRATCH_DISK",if=none,format=raw \
    -device nvme,serial=deadbeef,drive=nvm \
    -smp 2 -nographic -no-reboot -m 256M \
    -monitor none -serial stdio \
    > "$LOG" 2>&1 < /dev/null
rc=$?
set -e

echo "[test_nvme_io] --- captured (nvme / nvme_io_test / ext4 / kmod / bridge) ---"
grep -aE 'kmod_linux|\[nvme\.ko\]|\[nvme_io_test\]|\[nvme\]|\[boot:35\.N\]|\[bridge=|ext4: mounted|ext4: bad magic|ext4: failed' "$LOG" | head -80 || true
echo "[test_nvme_io] --- end ---"

# Panic / TRAP / BUG is unambiguously a regression.
if grep -aE -q "PANIC|panic:|TRAP:|BUG:" "$LOG"; then
    echo "[test_nvme_io] FAIL: kernel panic / trap"
    echo "[test_nvme_io] --- full log tail ---"
    tail -n 80 "$LOG"
    exit 1
fi

# Did the gating fire? boot:35.N is the marker we emit just before
# kmod_linux_load. If that's missing the marker plumbing itself is
# broken (the cpio entry didn't land, or the .ad gate is wrong).
if ! grep -aF -q "[boot:35.N] kmod_linux_load /lib/modules/6.12/nvme.ko" "$LOG"; then
    echo "[test_nvme_io] FAIL: /etc/nvme-io-ko marker not honoured"
    echo "[test_nvme_io] --- full log ---"
    tail -n 80 "$LOG"
    exit 1
fi

# Did the hand-rolled NVMe skip fire?
if ! grep -aF -q "[nvme] hand-rolled smoke-test SKIPPED" "$LOG"; then
    echo "[test_nvme_io] FAIL: hand-rolled nvme_smoke_test not gated"
    echo "[test_nvme_io] --- full log ---"
    tail -n 80 "$LOG"
    exit 1
fi
echo "[test_nvme_io] OK: hand-rolled smoke-test gated, .ko load attempted"

# [bridge=disabled] is the ground-truth marker that nvme_io_exercise
# is operating with NO fallback to the hand-rolled driver. Whether the
# test passes or fails this marker MUST fire — its absence means the
# gating is broken / the function ran in a wrong configuration.
if ! grep -aF -q "[bridge=disabled]" "$LOG"; then
    echo "[test_nvme_io] FAIL: [bridge=disabled] marker not observed"
    echo "[test_nvme_io] --- full log ---"
    tail -n 80 "$LOG"
    exit 1
fi
echo "[test_nvme_io] OK: [bridge=disabled] confirmed (no hand-rolled fallback)"

# The PASS / FAIL channel.
PASS_HIT=$(grep -acE "^\[[0-9]+\] \[nvme_io_test\] PASS|\[nvme_io_test\] PASS" "$LOG" || true)
PASS_HIT=${PASS_HIT:-0}
FAIL_HIT=$(grep -acE "\[nvme_io_test\] FAIL" "$LOG" || true)
FAIL_HIT=${FAIL_HIT:-0}

if [ "$PASS_HIT" -ge 1 ]; then
    echo "[test_nvme_io] PASS: shim-driven NVMe path mounted ext4 + read+wrote /hello.txt"
    exit 0
fi

if [ "$FAIL_HIT" -ge 1 ]; then
    # Pull the FAIL reason out of the log so the upstream report
    # carries the exact failure surface.
    echo "[test_nvme_io] FAIL (informative — surfaces an L-shim gap):"
    grep -aE "\[nvme_io_test\]" "$LOG" || true
    exit 1
fi

echo "[test_nvme_io] FAIL: no [nvme_io_test] marker seen (qemu rc=$rc)"
echo "[test_nvme_io] --- full log tail ---"
tail -n 80 "$LOG"
exit 1
