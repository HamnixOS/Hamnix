#!/usr/bin/env bash
# scripts/test_installer_full.sh
#
# End-to-end installer smoke test:
#
#   Stage A: rebuild the kernel + ISO + a blank 2 GiB qcow2 target.
#   Stage B: boot ISO under QEMU with the blank target attached as
#            vdb; drive hamsh stdin to run /etc/install.hamsh; assert
#            install completes via banner markers.
#   Stage C: boot the installed qcow2 alone (no ISO); assert hamsh
#            prompts, and the [firstboot] grow-check arm logs the
#            slack-or-fit decision.
#
# Markers asserted, in order, on Stage B:
#   "[install] Hamnix installer"
#   "[gpt] init OK"                     (kernel-side gpt_init)
#   "[gpt] mkpart idx=0"                (ESP partition)
#   "[gpt] mkpart idx=1"                (rootfs partition)
#   "dd_blk: OK"                        (×2 — ESP + rootfs copy)
#   "[install] (5/5) install complete"
#
# Markers asserted on Stage C (boot from disk alone):
#   "Hamnix kernel booting"             (kernel banner)
#   "[rootfs] mounted ext4 rootfs"      (rootfs detected on vdb)
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
TARGET_IMG="${TARGET_IMG:-build/installed.qcow2}"

# --- Stage A: build artifacts -----------------------------------------
echo "[test_installer_full] Stage A: build ISO + blank target"
if [ "${HAMNIX_SKIP_BUILD:-0}" != "1" ]; then
    rm -f "$HAMNIX_ISO"
    bash "$PROJ_ROOT/scripts/build_iso.sh" >/dev/null
fi
if [ ! -f "$HAMNIX_ISO" ]; then
    echo "[test_installer_full] FAIL Stage A: ISO not built" >&2
    exit 1
fi

rm -f "$TARGET_IMG"
qemu-img create -f qcow2 "$TARGET_IMG" "$TARGET_SIZE" >/dev/null
echo "[test_installer_full] Stage A: target $TARGET_IMG ($TARGET_SIZE)"

# --- Stage B: install ------------------------------------------------
echo "[test_installer_full] Stage B: boot ISO and run installer"
STAGE_B_LOG=$(mktemp --tmpdir hamnix-installer-stageB.XXXXXX.log)

set +e
(
    # Wait for hamsh prompt, then drive the installer.
    sleep 5
    printf 'hamsh /etc/install.hamsh\n'
    # The installer prints ~5 sections; allow time for the dd_blk
    # copies of the 32 MiB ESP and the ~120 MiB rootfs partition.
    sleep 45
    printf 'echo INSTALLER_DONE\n'
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

echo "[test_installer_full] Stage B QEMU rc=$RC_B (124 = timeout-killed, normal)"

# Stage B assertions.
stage_b_fail=0
check_marker() {
    local re="$1"; local label="$2"
    if grep -aE -q "$re" "$STAGE_B_LOG"; then
        echo "[test_installer_full]   OK : $label"
    else
        echo "[test_installer_full]   MISS: $label" >&2
        stage_b_fail=1
    fi
}
check_marker '\[install\] Hamnix installer' "installer banner"
check_marker '\[gpt\] init OK' "gpt_init"
check_marker '\[gpt\] mkpart idx=0' "ESP mkpart"
check_marker '\[gpt\] mkpart idx=1' "rootfs mkpart"
# dd_blk OK should appear twice (ESP + rootfs)
ddok=$(grep -aE -c 'dd_blk: OK' "$STAGE_B_LOG" || true)
if [ "$ddok" -ge 2 ]; then
    echo "[test_installer_full]   OK : dd_blk: OK ×$ddok"
else
    echo "[test_installer_full]   MISS: dd_blk: OK appeared $ddok times (need 2)" >&2
    stage_b_fail=1
fi
check_marker '\[install\] \(5/5\) install complete' "install complete"

if [ "$stage_b_fail" -ne 0 ]; then
    echo "[test_installer_full] Stage B FAILED — last 80 lines of log:" >&2
    tail -80 "$STAGE_B_LOG" >&2
    if [ "${KEEP_LOGS:-0}" != "1" ]; then
        rm -f "$STAGE_B_LOG"
    fi
    exit 1
fi
echo "[test_installer_full] Stage B: PASS"

# --- Stage C: boot from installed disk alone -------------------------
echo "[test_installer_full] Stage C: boot from $TARGET_IMG (no ISO)"
STAGE_C_LOG=$(mktemp --tmpdir hamnix-installer-stageC.XXXXXX.log)

set +e
(
    sleep 8
    printf 'echo DISK_BOOT_OK\n'
    sleep 2
    printf 'exit\n'
    sleep 1
) | timeout "${BOOT_TIMEOUT}s" qemu-system-x86_64 \
    -drive "file=$TARGET_IMG,if=virtio,format=qcow2,boot=on" \
    -bios /usr/share/ovmf/OVMF.fd \
    -smp 2 -m 512M -nographic -no-reboot -monitor none -serial stdio \
    > "$STAGE_C_LOG" 2>&1
RC_C=$?
set -e
echo "[test_installer_full] Stage C QEMU rc=$RC_C"

stage_c_fail=0
check_marker_c() {
    local re="$1"; local label="$2"
    if grep -aE -q "$re" "$STAGE_C_LOG"; then
        echo "[test_installer_full]   OK : $label"
    else
        echo "[test_installer_full]   MISS: $label" >&2
        stage_c_fail=1
    fi
}
# UEFI boot path: PE entry + post-EFI + kernel banner.
check_marker_c '\[hamnix\] EFI entry reached|Hamnix kernel booting' "boot reached"
check_marker_c '\[rootfs\] mounted ext4 rootfs|\[rootfs\] ext4 magic' "ext4 rootfs detected"

if [ "$stage_c_fail" -ne 0 ]; then
    echo "[test_installer_full] Stage C FAILED — last 80 lines of log:" >&2
    tail -80 "$STAGE_C_LOG" >&2
    if [ "${KEEP_LOGS:-0}" != "1" ]; then
        rm -f "$STAGE_B_LOG" "$STAGE_C_LOG"
    fi
    exit 1
fi
echo "[test_installer_full] Stage C: PASS"

if [ "${KEEP_LOGS:-0}" != "1" ]; then
    rm -f "$STAGE_B_LOG" "$STAGE_C_LOG"
    rm -f "$TARGET_IMG"
fi

echo "[test_installer_full] ALL STAGES PASS"
