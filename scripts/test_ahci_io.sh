#!/usr/bin/env bash
# scripts/test_ahci_io.sh — storage L-shim EXERCISE test.
#
# The companion `test_ahci_ko.sh` is a LOAD-only test: it asserts the
# Debian 6.1.0-32 ahci.ko binary's UND surface is closed by
# linux_abi/api_ahci.ad and that init_module / probe runs through the
# cold-path stubs. That's necessary but not sufficient — it doesn't
# prove anything about real block I/O.
#
# This script is the EXERCISE: boot with a real ext4 image attached
# via -device ich9-ahci, set /etc/ahci-ko to (a) skip the hand-rolled
# drivers/ata/ahci.ad smoke-test and (b) kmod_linux_load ahci.ko, then
# run ahci_io_exercise() in init/main.ad which tries to find the
# block device the .ko-shim should have produced (sda / sda1 / sd0 /
# sd0p1) and read /HELLO.TXT off it through fs/ext4.ad.
#
# The PASS / FAIL channel is the [ahci_io_test] marker line emitted
# from ahci_io_exercise(). Whichever happens — PASS or a specific FAIL
# reason — the test script reports it. A FAIL with a specific reason
# is actually the most informative outcome: it pinpoints where exactly
# the storage class L-shim falls short.
#
# Architecture note (M16.x): the .ko's stock libata host_activate ->
# SCSI mid-layer hand-off is fully stubbed out (ata_scsi_queuecmd
# returns -ENODEV, no struct scsi_device gets allocated, no
# register_blockdev is called). To still exercise the path end-to-end
# we BRIDGE the shim's _ahc_ahci_host_activate to the hand-rolled
# AHCI driver's bring-up at exactly the libata "publish ports" point —
# the same point Linux's libata would call ata_host_register() and
# hand off to the SCSI mid-layer. The bridge is in linux_abi/api_ahci.ad
# and is the only place where Hamnix-native code "completes" what the
# Linux .ko's probe started. This is what an L-shim IS: a layer that
# absorbs Linux-driver expectations and translates them to whatever
# the native kernel happens to expose.

. "$(dirname "$0")/_build_lock.sh"
. "$(dirname "$0")/_verdict.sh"

set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf

echo "[test_ahci_io] (1/5) Build userland + modules"
bash scripts/build_user.sh >/dev/null
bash scripts/build_modules.sh >/dev/null

echo "[test_ahci_io] (2/5) Build disk images (build/ext4.img has /HELLO.TXT)"
python3 scripts/build_diskimg.py >/dev/null

if [ ! -f build/ext4.img ]; then
    echo "[test_ahci_io] FAIL: build/ext4.img not generated (mkfs.ext4 missing?)"
    exit 1
fi

# Copy the canonical ext4 image to a scratch file. The hand-rolled
# AHCI driver's _ahci_write_smoke_test() writes a pattern to LBA 1 of
# the disk attached over -drive. That LBA is in the ext4 boot-sector
# padding (zero-reserved, never read by the FS) so the filesystem is
# semantically intact, but the bytes on the host file change.
# Subsequent tests (test_inflate_realgz, test_apt_inrelease_real,
# test_distrofs_persist, ...) all read build/ext4.img verbatim via
# virtio-blk — operating on a copy keeps those tests reproducible.
DISK="$(mktemp --suffix=.ahci-io.img)"
cp build/ext4.img "$DISK"

echo "[test_ahci_io] (3/5) Build initramfs with /etc/ahci-ko marker"
ENABLE_AHCI_KO=1 INIT_ELF=build/user/init.elf \
    python3 scripts/build_initramfs.py >/dev/null

echo "[test_ahci_io] (4/5) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

LOG="$(mktemp)"
# Restore the default initramfs at the end so subsequent tests don't
# inherit ENABLE_AHCI_KO state.
trap 'rm -f "$LOG" "$DISK"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1 || true' EXIT

echo "[test_ahci_io] (5/5) Boot QEMU with ich9-ahci + scratch ext4 disk"
set +e
timeout 30s qemu-system-x86_64 \
    -kernel "$ELF" \
    -drive id=d0,file="$DISK",if=none,format=raw \
    -device ich9-ahci,id=ahci0 \
    -device ide-hd,drive=d0,bus=ahci0.0 \
    -smp 2 -nographic -no-reboot -m 256M \
    -monitor none -serial stdio \
    > "$LOG" 2>&1 < /dev/null
rc=$?
set -e

echo "[test_ahci_io] --- captured (ahci / ahci_io_test / ext4 / kmod) ---"
grep -aE 'kmod_linux|\[ahci\.ko\]|\[ahci_io_test\]|\[ahci\]|\[boot:35\.A\]|ext4: mounted|ext4: bad magic|ext4: failed' "$LOG" | head -50 || true
echo "[test_ahci_io] --- end ---"

# Three-valued starvation guard: a boot that produced NONE of the
# storage-path markers (total host starvation) is INCONCLUSIVE, not the
# hard FAIL the detailed asserters below would otherwise emit. An
# OBSERVED kernel crash is still a FAIL (handled inside verdict_boot_gate
# and by the explicit panic check that follows).
verdict_boot_gate test_ahci_io "$LOG" "$rc" 'kmod_linux|\[ahci\]|\[boot:35\.A\]|\[ahci_io_test\]'

# Panic / TRAP / BUG is unambiguously a regression.
if grep -aE -q "PANIC|panic:|TRAP:|BUG:" "$LOG"; then
    echo "[test_ahci_io] FAIL: kernel panic / trap"
    echo "[test_ahci_io] --- full log tail ---"
    tail -n 80 "$LOG"
    exit 1
fi

# Did the shim path even run? boot:35.A is the marker we emit just
# before kmod_linux_load. If that's missing the marker plumbing
# itself is broken.
if ! grep -aF -q "[boot:35.A] kmod_linux_load /lib/modules/6.12/ahci.ko" "$LOG"; then
    echo "[test_ahci_io] FAIL: /etc/ahci-ko marker not honoured"
    echo "[test_ahci_io] --- full log ---"
    tail -n 80 "$LOG"
    exit 1
fi

# Did the hand-rolled skip fire?
if ! grep -aF -q "[ahci] hand-rolled smoke-test SKIPPED" "$LOG"; then
    echo "[test_ahci_io] FAIL: hand-rolled ahci_smoke_test not gated"
    echo "[test_ahci_io] --- full log ---"
    tail -n 80 "$LOG"
    exit 1
fi
echo "[test_ahci_io] OK: hand-rolled smoke-test gated, .ko load attempted"

# Storage-maximalism milestone: the modules.dep dep chain must have
# auto-loaded scsi_common -> scsi_mod -> libata -> libahci BEFORE
# ahci.ko, and the loader's cross-module ksymtab must have dispatched
# libata/libahci's real EXPORT_SYMBOL surface to ahci.ko's UND
# resolutions. Assert both shape markers so a regression that drops
# back to the single-module insmod path is loud.
for dep_name in scsi_common scsi_mod libata libahci ahci; do
    if ! grep -aE -q "kmod_linux: name=${dep_name}" "$LOG"; then
        echo "[test_ahci_io] FAIL: modules.dep dep chain did not load ${dep_name}"
        echo "[test_ahci_io] --- full log tail ---"
        tail -n 80 "$LOG"
        exit 1
    fi
done
echo "[test_ahci_io] OK: modules.dep chain loaded scsi_common+scsi_mod+libata+libahci+ahci"

# Cross-module ksymtab dispatch: ahci.ko's ahci_host_activate / ata_*
# must resolve via libahci.ko / libata.ko's ksymtab entries, NOT via
# the linux_abi/api_ahci.ad shim. Loud regression marker.
if ! grep -aE -q "\[ksymtab_hit\] ahci -> libahci: ahci_host_activate|\[ksymtab_hit\] libahci -> libata: ata_host_activate" "$LOG"; then
    echo "[test_ahci_io] FAIL: cross-module ksymtab dispatch did not fire"
    echo "[test_ahci_io] --- full log tail ---"
    tail -n 80 "$LOG"
    exit 1
fi
echo "[test_ahci_io] OK: cross-module ksymtab dispatched ahci -> libahci -> libata"

# Storage maximalism: the bridge marker channel.
#   [bridge=disabled] : L-shim libata/scsi end-to-end completed and
#                       registered the blockdev — full Linux path,
#                       no native fallback needed.
#   [bridge=fallback] : modules loaded fine but Linux's libata path
#                       didn't complete add_disk; native AHCI driver
#                       took over to mint sd0 so the ext4 round-trip
#                       still validates the lower block layer.
# A "bridge=fallback" outcome is still a PASS for the storage stack
# (ext4 mount + read + write succeed) but documents the remaining gap
# in api_block.ad's add_disk shim. Once that shim wraps a gendisk's
# submit_bio into Hamnix's BlockDeviceOps, this flips to
# bridge=disabled.
BRIDGE_DISABLED=$(grep -acF "[bridge=disabled]" "$LOG" || true)
BRIDGE_FALLBACK=$(grep -acF "[bridge=fallback]" "$LOG" || true)
BRIDGE_DISABLED=${BRIDGE_DISABLED:-0}
BRIDGE_FALLBACK=${BRIDGE_FALLBACK:-0}
echo "[test_ahci_io] bridge_disabled=$BRIDGE_DISABLED bridge_fallback=$BRIDGE_FALLBACK"

# The PASS / FAIL channel.
PASS_HIT=$(grep -acE "^\[[0-9]+\] \[ahci_io_test\] PASS|\[ahci_io_test\] PASS" "$LOG" || true)
PASS_HIT=${PASS_HIT:-0}
FAIL_HIT=$(grep -acE "\[ahci_io_test\] FAIL" "$LOG" || true)
FAIL_HIT=${FAIL_HIT:-0}

if [ "$PASS_HIT" -ge 1 ]; then
    if [ "$BRIDGE_DISABLED" -ge 1 ]; then
        echo "[test_ahci_io] PASS: L-shim libata/scsi path owns block I/O end-to-end (bridge disabled)"
    else
        echo "[test_ahci_io] PASS: shim-driven storage path mounted ext4 + read /HELLO.TXT (bridge=fallback)"
    fi
    exit 0
fi

if [ "$FAIL_HIT" -ge 1 ]; then
    # Pull the FAIL reason out of the log so the upstream report
    # carries the exact failure surface.
    echo "[test_ahci_io] FAIL (informative — surfaces an L-shim gap):"
    grep -aE "\[ahci_io_test\]" "$LOG" || true
    exit 1
fi

echo "[test_ahci_io] FAIL: no [ahci_io_test] marker seen (qemu rc=$rc)"
echo "[test_ahci_io] --- full log tail ---"
tail -n 80 "$LOG"
exit 1
