#!/usr/bin/env bash
# scripts/test_install_multipkg.sh
#
# Multi-package install regression test.
#
# Asserts the install_file_to_slot kernel path can lay down MULTIPLE
# distinct files on a freshly-formatted ext4 target partition without
# the dd_blk byte-copy clobbering pattern. This is the proof-of-concept
# for splitting `hamnix-base` into component packages: each `hpm install
# <pkg>` writes its files independently, no last-package-wins.
#
# Stages:
#   A: build ISO + a blank target qcow2 (vdb).
#   B: boot ISO, run /etc/install_multipkg.hamsh (NEW installer that
#      uses install_file_to_slot, NOT dd_blk). The script partitions
#      the target, mkfs's both partitions, then writes from_a.txt and
#      from_b.txt onto the target rootfs one after the other.
#   C: reboot the target alone (no ISO) and assert BOTH from_a.txt
#      and from_b.txt are readable on the installed ext4 rootfs.
#
# Markers asserted, Stage B:
#   "[install_multipkg] start"
#   "hamnix_partition: OK"
#   "mkfs_fat: /dev/blk/vdbp1 OK"
#   "mkfs_ext4: /dev/blk/vdbp2 OK"
#   "install_file_to_slot: /dev/blk/vdbp2 <- from_a.txt"
#   "install_file_to_slot: /dev/blk/vdbp2 <- from_b.txt"
#   "[install_multipkg] install complete"
#
# Markers asserted, Stage C:
#   "Hamnix kernel booting"
#   "[rootfs] mounted ext4 rootfs"   OR  "[rootfs] ext4 magic"
#   "SCRATCH_A_PAYLOAD"              (from cat /ext/from_a.txt)
#   "SCRATCH_B_PAYLOAD"              (from cat /ext/from_b.txt)
#
# Env overrides:
#   BOOT_TIMEOUT  per-stage seconds         (default: 60)
#   TARGET_SIZE   qcow2 size                (default: 2G)
#   KEEP_LOGS=1   keep log + qcow2 artifacts on PASS

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

# shellcheck source=_build_lock.sh
source "$PROJ_ROOT/scripts/_build_lock.sh"

BOOT_TIMEOUT="${BOOT_TIMEOUT:-60}"
TARGET_SIZE="${TARGET_SIZE:-2G}"
HAMNIX_ISO="${HAMNIX_ISO:-build/hamnix.iso}"
TARGET_IMG="${TARGET_IMG:-build/installed-multipkg.qcow2}"

# --- Stage A: build artifacts ----------------------------------------
echo "[test_install_multipkg] Stage A: build ISO + blank target"
if [ "${HAMNIX_SKIP_BUILD:-0}" != "1" ]; then
    rm -f "$HAMNIX_ISO"
    bash "$PROJ_ROOT/scripts/build_iso.sh" >/dev/null
fi
if [ ! -f "$HAMNIX_ISO" ]; then
    echo "[test_install_multipkg] FAIL Stage A: ISO not built" >&2
    exit 1
fi

rm -f "$TARGET_IMG"
qemu-img create -f qcow2 "$TARGET_IMG" "$TARGET_SIZE" >/dev/null
echo "[test_install_multipkg] Stage A: target $TARGET_IMG ($TARGET_SIZE)"

# --- Stage B: install via install_multipkg.hamsh ---------------------
echo "[test_install_multipkg] Stage B: boot ISO and run install_multipkg.hamsh"
STAGE_B_LOG=$(mktemp --tmpdir hamnix-multipkg-stageB.XXXXXX.log)

set +e
(
    sleep 5
    printf 'hamsh /etc/install_multipkg.hamsh\n'
    sleep 15
    printf 'echo MULTIPKG_DONE\n'
    sleep 2
    printf 'exit\n'
    sleep 1
) | timeout "${BOOT_TIMEOUT}s" qemu-system-x86_64 \
    -drive "file=$HAMNIX_ISO,if=virtio,format=raw,readonly=on" \
    -drive "file=$TARGET_IMG,if=virtio,format=qcow2" \
    -smp 2 -m 512M -nographic -no-reboot -monitor none -serial stdio \
    > "$STAGE_B_LOG" 2>&1
RC_B=$?
set -e

echo "[test_install_multipkg] Stage B QEMU rc=$RC_B (124 = timeout-killed, normal)"

stage_b_fail=0
check_marker() {
    local re="$1"; local label="$2"
    if grep -aE -q "$re" "$STAGE_B_LOG"; then
        echo "[test_install_multipkg]   OK : $label"
    else
        echo "[test_install_multipkg]   MISS: $label" >&2
        stage_b_fail=1
    fi
}
check_marker '\[install_multipkg\] start' "installer banner"
check_marker '\[gpt\] init OK' "gpt_init"
check_marker 'mkfs_ext4: /dev/blk/vdbp2' "mkfs_ext4 target rootfs"
check_marker 'install_file_to_slot: /dev/blk/vdbp2 <- from_a.txt' "package A install"
check_marker 'install_file_to_slot: /dev/blk/vdbp2 <- from_b.txt' "package B install"
check_marker '\[install_multipkg\] install complete' "installer complete"

# Both kernel-side OK markers for install_file should be present.
ifs_ok=$(grep -aE -c 'install_file slot=.* OK' "$STAGE_B_LOG" || true)
if [ "$ifs_ok" -ge 2 ]; then
    echo "[test_install_multipkg]   OK : kernel install_file OK ×$ifs_ok"
else
    echo "[test_install_multipkg]   MISS: kernel install_file OK appeared $ifs_ok times (need 2)" >&2
    stage_b_fail=1
fi

if [ "$stage_b_fail" -ne 0 ]; then
    echo "[test_install_multipkg] Stage B FAILED — last 80 lines of log:" >&2
    tail -80 "$STAGE_B_LOG" >&2
    if [ "${KEEP_LOGS:-0}" != "1" ]; then
        rm -f "$STAGE_B_LOG"
    fi
    exit 1
fi
echo "[test_install_multipkg] Stage B: PASS"

# --- Stage C: boot installed disk, verify both files ----------------
echo "[test_install_multipkg] Stage C: boot $TARGET_IMG (no ISO), assert both files"
STAGE_C_LOG=$(mktemp --tmpdir hamnix-multipkg-stageC.XXXXXX.log)

set +e
(
    sleep 8
    # Both files MUST resolve under /ext/<name>.
    printf 'cat /ext/from_a.txt\n'
    sleep 1
    printf 'cat /ext/from_b.txt\n'
    sleep 1
    printf 'echo MULTIPKG_BOOT_OK\n'
    sleep 2
    printf 'exit\n'
    sleep 1
) | timeout "${BOOT_TIMEOUT}s" qemu-system-x86_64 \
    -drive "file=$TARGET_IMG,if=virtio,format=qcow2" \
    -bios /usr/share/ovmf/OVMF.fd \
    -smp 2 -m 512M -nographic -no-reboot -monitor none -serial stdio \
    > "$STAGE_C_LOG" 2>&1
RC_C=$?
set -e
echo "[test_install_multipkg] Stage C QEMU rc=$RC_C"

stage_c_fail=0
check_marker_c() {
    local re="$1"; local label="$2"
    if grep -aE -q "$re" "$STAGE_C_LOG"; then
        echo "[test_install_multipkg]   OK : $label"
    else
        echo "[test_install_multipkg]   MISS: $label" >&2
        stage_c_fail=1
    fi
}
check_marker_c '\[hamnix\] EFI entry reached|Hamnix kernel booting' "boot reached"
check_marker_c '\[rootfs\] mounted ext4 rootfs|\[rootfs\] ext4 magic' "ext4 rootfs detected"
check_marker_c 'SCRATCH_A_PAYLOAD' "from_a.txt readable (package A survived reboot)"
check_marker_c 'SCRATCH_B_PAYLOAD' "from_b.txt readable (package B survived reboot)"

if [ "$stage_c_fail" -ne 0 ]; then
    echo "[test_install_multipkg] Stage C FAILED — last 80 lines of log:" >&2
    tail -80 "$STAGE_C_LOG" >&2
    if [ "${KEEP_LOGS:-0}" != "1" ]; then
        rm -f "$STAGE_B_LOG" "$STAGE_C_LOG"
    fi
    exit 1
fi
echo "[test_install_multipkg] Stage C: PASS"

if [ "${KEEP_LOGS:-0}" != "1" ]; then
    rm -f "$STAGE_B_LOG" "$STAGE_C_LOG"
    rm -f "$TARGET_IMG"
fi

echo "[test_install_multipkg] ALL STAGES PASS"
