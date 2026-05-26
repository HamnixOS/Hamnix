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
# OFF via /etc/nvme-io-ko, then dep-load nvme-core.ko + nvme.ko via
# modules_dep_load_with_deps("nvme") so the cross-module ksymtab
# replaces api_nvme.ad's cold-path stubs with nvme-core's REAL
# EXPORT_SYMBOL impls, and finally run nvme_io_exercise() in
# init/main.ad which tries to find a block device that the .ko-shim
# path produced and read /hello.txt off it through fs/ext4.ad.
#
# Critical difference from test_ahci_io.sh: NO BRIDGE. The AHCI
# exercise routes _ahc_ahci_host_activate back to the hand-rolled
# drivers/ata/ahci.ad bring-up so the L-shim "completes" what the
# Linux .ko's probe started. The NVMe exercise does NOT do that.
# If nvme.ko + nvme-core.ko can't carry namespace scan + add_disk
# end-to-end on the L-shim, that's a finding, not a thing to paper
# over.
#
# Strict assertions (added with the nvme-core side-load milestone):
#   * Hand-rolled SKIPPED marker fires.
#   * boot:35.N modules_dep_load_with_deps marker fires.
#   * BOTH nvme-core.ko AND nvme.ko load (loader emits name=X for
#     each in its .modinfo pass).
#   * Cross-module ksymtab dispatches: [ksymtab_hit] nvme ->
#     nvme_core: nvme_submit_sync_cmd MUST fire — that's the
#     entire reason for the side-load.
#   * [bridge=disabled] fires (no hand-rolled fallback).
#
# PASS path: nvme_io_exercise mounts ext4 from the nvme0n1 block
# device the L-shim Option X finish bridge registered, reads + writes
# + verifies /hello.txt.
#
# Bring-up structure (Option X): nvme.ko's nvme_probe returns -EINVAL
# early in our env — and even if it succeeded, nvme_reset_work would
# be queued on nvme_wq which has no kthread servicing it (flush_work
# is a no-op stub). So nvme-core's reset -> identify -> scan ->
# add_disk chain never reaches device_add_disk on its own. The
# L-shim closes the gap via linux_abi_finish_nvme_add_disk in
# api_nvme_core.ad, invoked from init/main.ad's boot:35.N path
# AFTER modules_dep_load_with_deps("nvme") returns. The finish
# function drives CC.EN + admin IDENTIFY + create I/O queues +
# register_blockdev("nvme0n1", ...) directly via helpers imported
# from drivers/nvme/nvme.ad (same path the default boot flow uses
# when /etc/nvme-io-ko is absent). Mirror of AHCI's
# linux_abi_finish_ahci_add_disk approach.
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

echo "[test_nvme_io] --- captured (nvme / nvme_io_test / ext4 / kmod / bridge / ksymtab) ---"
grep -aE 'kmod_linux: name=|\[nvme\.ko\]|\[nvme_io_test\]|\[nvme\]|\[nvme_core\]|\[boot:35\.N\]|\[bridge=|\[ksymtab_hit\] nvme |\[pci_register_driver\]|ext4: mounted|ext4: bad magic|ext4: failed' "$LOG" | head -120 || true
echo "[test_nvme_io] --- end ---"

# Stash the full raw log for post-mortem (mirrors test_nvme_ko.sh).
cp "$LOG" /tmp/test_nvme_io.last.log || true

# Panic / TRAP / BUG is unambiguously a regression.
if grep -aE -q "PANIC|panic:|TRAP:|BUG:" "$LOG"; then
    echo "[test_nvme_io] FAIL: kernel panic / trap"
    echo "[test_nvme_io] --- full log tail ---"
    tail -n 80 "$LOG"
    exit 1
fi

# Did the gating fire? boot:35.N is the marker we emit just before
# the dep-aware loader walks nvme's deps (nvme-core then nvme). If
# that's missing the marker plumbing itself is broken (the cpio
# entry didn't land, or the .ko-shim gate is wrong).
if ! grep -aF -q "[boot:35.N] modules_dep_load_with_deps nvme" "$LOG"; then
    echo "[test_nvme_io] FAIL: /etc/nvme-io-ko marker not honoured"
    echo "[test_nvme_io] --- full log ---"
    tail -n 80 "$LOG"
    exit 1
fi

# Storage-maximalism shape: BOTH nvme-core AND nvme must load via
# the dep walker. The loader announces each module's name= line just
# after parsing .modinfo. Missing either means the chain broke.
if ! grep -aF -q "kmod_linux: name=nvme_core" "$LOG"; then
    echo "[test_nvme_io] FAIL: nvme-core.ko did not load (chain broke before nvme)"
    echo "[test_nvme_io] --- full log tail ---"
    tail -n 80 "$LOG"
    exit 1
fi
if ! grep -aE -q "kmod_linux: name=nvme$" "$LOG"; then
    echo "[test_nvme_io] FAIL: nvme.ko did not load"
    echo "[test_nvme_io] --- full log tail ---"
    tail -n 80 "$LOG"
    exit 1
fi
echo "[test_nvme_io] OK: nvme-core.ko + nvme.ko both loaded via dep walker"

# Cross-module ksymtab resolution proof: nvme.ko's relocations must
# dispatch through nvme-core's EXPORT_SYMBOL entries. The critical
# symbol is nvme_submit_sync_cmd — the entire reason for the
# side-load. If we don't see [ksymtab_hit] nvme -> nvme_core:
# nvme_submit_sync_cmd then the api_nvme.ad cold-path -ENODEV stub
# is still in play.
if ! grep -aF -q "[ksymtab_hit] nvme -> nvme_core: nvme_submit_sync_cmd" "$LOG"; then
    echo "[test_nvme_io] FAIL: cross-module ksymtab did NOT resolve nvme_submit_sync_cmd"
    echo "  (api_nvme.ad cold-path stub still in play; nvme-core side-load not effective)"
    echo "[test_nvme_io] --- full log tail ---"
    tail -n 80 "$LOG"
    exit 1
fi
echo "[test_nvme_io] OK: cross-module ksymtab dispatch confirmed (nvme -> nvme_core: nvme_submit_sync_cmd)"

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

# Option X L-shim add_disk completion marker. linux_abi_finish_nvme_add_disk
# is invoked from boot:35.N AFTER modules_dep_load_with_deps("nvme") and
# is what actually carries the controller bring-up (CC.EN + IDENTIFY +
# create I/O queues + register_blockdev) since nvme.ko's reset_work
# never runs in our env. Its absence means either the finish path
# wasn't called or it bailed before reaching the registration step.
if ! grep -aF -q "[nvme.ko] linux_finish: NVMe bring-up via L-shim Option X bridge" "$LOG"; then
    echo "[test_nvme_io] FAIL: L-shim finish bridge did not fire"
    echo "[test_nvme_io] --- full log tail ---"
    tail -n 80 "$LOG"
    exit 1
fi
echo "[test_nvme_io] OK: L-shim finish bridge fired (Option X bring-up)"

# And the bridge actually registered the block device.
if ! grep -aF -q "[bridge=disabled] nvme0n1 registered" "$LOG"; then
    echo "[test_nvme_io] FAIL: nvme0n1 was not registered by the finish bridge"
    echo "[test_nvme_io] --- full log tail ---"
    tail -n 80 "$LOG"
    exit 1
fi
echo "[test_nvme_io] OK: finish bridge registered nvme0n1"

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
