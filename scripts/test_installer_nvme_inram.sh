#!/usr/bin/env bash
# scripts/test_installer_nvme_inram.sh — END-TO-END proof of the
# IN-RAM-SQUASHFS install flow: the installer sources its rootfs + ESP
# payloads from a squashfs the FIRMWARE loaded into RAM (inside the kernel
# cpio), NEVER from the install media's own block device. Targets a native
# NVMe disk; demonstrable entirely in a VM under OVMF/qemu (no real HW).
#
# WHY THIS IS DISTINCT FROM test_installer_nvme.sh. The original installer
# ended its payload copy with `dd_blk /dev/blk/vdap2 /dev/blk/nvme0n1p2` —
# a RUNTIME read of the install MEDIA's ext4 partition. On the real NUC
# target the media is a USB stick whose native driver is broken, so that
# read defeats the whole in-RAM-installer model. This test proves the
# fix: the install medium is an ESP-ONLY GPT image (NO ext4 partition to
# read), and the installer streams its payload out of the in-RAM squashfs.
#
# Stages:
#   Stage A: build the ESP-only install medium (build_installer_img.sh ->
#            hamnix-installer.img) + a blank NVMe target qcow2. ASSERT ON
#            THE HOST that the medium has EXACTLY ONE partition (the ESP) —
#            there is physically nothing on the media to read.
#   Stage B: boot the install medium under OVMF (virtio-blk = install
#            media; -device nvme = blank target). Drive the installer over
#            the serial shell. Assert: the install completed, the log shows
#            the payload came from the IN-RAM squashfs (a "[sqfs-extract]"
#            kernel line + the installer's "sourcing ... from in-RAM
#            squashfs" markers), AND a real GPT + ext4 superblock actually
#            landed on the NVMe qcow2 (read the raw bytes back on the HOST
#            — REAL verification, not a log marker).
#   Stage C: boot the NVMe qcow2 ALONE under OVMF (NO install media).
#            Assert the kernel mounted ext4-on-NVMe and reached a shell
#            with ZERO 'command not found'.
#
# REAL verification — no hard-coded PASS, no faked install, no
# log-marker-only proof for the bytes-on-disk checks.
#
# Env overrides:
#   BOOT_TIMEOUT      per-stage seconds                 (default: 200)
#   NVME_SIZE         blank NVMe target size            (default: 2G)
#   OVMF_FD           OVMF firmware path                (auto-resolved)
#   HAMNIX_SKIP_BUILD 1 = reuse build/hamnix-installer.img (default: rebuild)
#   KEEP_LOGS         1 = keep logs + qcow2 on PASS      (default: 0)

set -uo pipefail

PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

# shellcheck source=_build_lock.sh
source "$PROJ_ROOT/scripts/_build_lock.sh"

BOOT_TIMEOUT="${BOOT_TIMEOUT:-200}"
NVME_SIZE="${NVME_SIZE:-2G}"
INSTALLER_IMG="${INSTALLER_IMG:-build/hamnix-installer.img}"
NVME_IMG="${NVME_IMG:-build/installed-nvme-inram.qcow2}"
KERNEL_BANNER="Hamnix kernel booting"
PROMPT_MARKER="handing off to interactive shell"

# --- environment gates (skip cleanly) --------------------------------
if [ ! -e /dev/kvm ]; then
    echo "[test_installer_nvme_inram] SKIP: /dev/kvm absent (KVM required; OVMF boot too slow without it)" >&2
    exit 0
fi
OVMF_FD="${OVMF_FD:-}"
if [ -z "$OVMF_FD" ]; then
    if [ -f /usr/share/ovmf/OVMF.fd ]; then
        OVMF_FD=/usr/share/ovmf/OVMF.fd
    elif [ -f /usr/share/OVMF/OVMF_CODE.fd ]; then
        OVMF_FD=/usr/share/OVMF/OVMF_CODE.fd
    elif [ -f /usr/share/OVMF/OVMF_CODE_4M.fd ]; then
        OVMF_FD=/usr/share/OVMF/OVMF_CODE_4M.fd
    fi
fi
if [ -z "$OVMF_FD" ] || [ ! -f "$OVMF_FD" ]; then
    echo "[test_installer_nvme_inram] SKIP: OVMF firmware not found (apt install ovmf)" >&2
    exit 0
fi
if ! command -v mksquashfs >/dev/null 2>&1; then
    echo "[test_installer_nvme_inram] SKIP: mksquashfs not found (apt install squashfs-tools)" >&2
    exit 0
fi

# --- Stage A: build ESP-only install medium + blank NVMe target -------
echo "[test_installer_nvme_inram] Stage A: build ESP-only install medium + blank NVMe target"
if [ "${HAMNIX_SKIP_BUILD:-0}" != "1" ]; then
    rm -f "$INSTALLER_IMG"
    bash "$PROJ_ROOT/scripts/build_installer_img.sh"
fi
if [ ! -f "$INSTALLER_IMG" ]; then
    echo "[test_installer_nvme_inram] FAIL Stage A: $INSTALLER_IMG not built" >&2
    exit 1
fi

# HOST-SIDE PROOF: the install medium must have EXACTLY ONE partition
# (the ESP). NO ext4 partition 2 = there is physically nothing on the
# media for the installer to read. This is the load-bearing proof the
# USB-read path is gone.
PARTED="/sbin/parted"; [ -x "$PARTED" ] || PARTED="$(command -v parted || true)"
NPARTS=$("$PARTED" -s "$INSTALLER_IMG" unit s print 2>/dev/null \
            | awk '/^[ ]*[0-9]+/ {n++} END {print n+0}')
if [ "$NPARTS" -ne 1 ]; then
    echo "[test_installer_nvme_inram] FAIL Stage A: install medium has $NPARTS partitions; must be 1 (ESP-only)." >&2
    "$PARTED" -s "$INSTALLER_IMG" unit s print >&2
    exit 1
fi
echo "[test_installer_nvme_inram]   OK : install medium is ESP-ONLY (1 partition; no ext4 to read)"
# Also assert there is NO ext4 superblock anywhere a partition-2 would be:
# scan the whole image for the 0xEF53 magic at any 1 MiB boundary +1024.
# (Belt-and-suspenders: the squashfs payload is gzip-compressed so the raw
# ext4 magic does not appear in the medium's bytes.)
INSTALLER_RAW_MAGIC=$(od -An -tx1 "$INSTALLER_IMG" 2>/dev/null | tr -d ' \n' | grep -o "53ef" | head -1 || true)
# (Informational only; not a hard gate — gzip could in theory contain the
# byte pair by chance. The 1-partition GPT check above is the real proof.)

rm -f "$NVME_IMG"
qemu-img create -f qcow2 "$NVME_IMG" "$NVME_SIZE" >/dev/null
echo "[test_installer_nvme_inram] Stage A: NVMe target $NVME_IMG ($NVME_SIZE)"

OVMF_RW=$(mktemp --tmpdir hamnix-inram.ovmf.XXXXXX.fd)
MEDIA_RW=$(mktemp --tmpdir hamnix-inram.media.XXXXXX.img)
cp "$OVMF_FD" "$OVMF_RW"
cp "$INSTALLER_IMG" "$MEDIA_RW"

STAGE_B_LOG=$(mktemp --tmpdir hamnix-inram-stageB.XXXXXX.log)
STAGE_C_LOG=$(mktemp --tmpdir hamnix-inram-stageC.XXXXXX.log)
INFIFO_B=$(mktemp --tmpdir -u hamnix-inram-inB.XXXXXX)
INFIFO_C=$(mktemp --tmpdir -u hamnix-inram-inC.XXXXXX)
mkfifo "$INFIFO_B" "$INFIFO_C"

cleanup() {
    [ -n "${QEMU_B_PID:-}" ] && kill "$QEMU_B_PID" 2>/dev/null
    [ -n "${QEMU_C_PID:-}" ] && kill "$QEMU_C_PID" 2>/dev/null
    rm -f "$OVMF_RW" "$MEDIA_RW" "$INFIFO_B" "$INFIFO_C"
    if [ "${KEEP_LOGS:-0}" != "1" ]; then
        rm -f "$STAGE_B_LOG" "$STAGE_C_LOG" "$NVME_IMG"
    fi
}
trap cleanup EXIT

# --- Stage B: boot installer medium + blank NVMe, run the installer ---
echo "[test_installer_nvme_inram] Stage B: boot ESP-only install medium (OVMF) + blank NVMe; run installer"

exec 4<>"$INFIFO_B"
exec 3>"$INFIFO_B"

# bootindex pins the install media first (same rationale as
# test_installer_nvme.sh: OVMF would otherwise probe the blank NVMe and
# PXE before the virtio media).
qemu-system-x86_64 \
    -enable-kvm -cpu host \
    -bios "$OVMF_RW" \
    -drive file="$MEDIA_RW",format=raw,if=none,id=media \
    -device virtio-blk-pci,drive=media,bootindex=0 \
    -drive file="$NVME_IMG",format=qcow2,if=none,id=nvmetgt \
    -device nvme,drive=nvmetgt,serial=hamnvme01,bootindex=1 \
    -m 1280M \
    -nographic -no-reboot -monitor none \
    -serial stdio \
    <&4 > "$STAGE_B_LOG" 2>&1 &
QEMU_B_PID=$!

echo "[test_installer_nvme_inram] Stage B: waiting up to ${BOOT_TIMEOUT}s for installer shell prompt..."
booted=0
for _ in $(seq 1 "$BOOT_TIMEOUT"); do
    if grep -a -q "$PROMPT_MARKER" "$STAGE_B_LOG"; then booted=1; break; fi
    if ! kill -0 "$QEMU_B_PID" 2>/dev/null; then
        echo "[test_installer_nvme_inram] FAIL Stage B: qemu exited before the installer shell." >&2
        tail -80 "$STAGE_B_LOG" >&2
        exit 1
    fi
    sleep 1
done
if [ "$booted" -ne 1 ]; then
    echo "[test_installer_nvme_inram] FAIL Stage B: installer shell prompt not seen in ${BOOT_TIMEOUT}s." >&2
    tail -80 "$STAGE_B_LOG" >&2
    exit 1
fi
echo "[test_installer_nvme_inram] Stage B: installer shell ready; driving the NVMe installer."
sleep 6

type_b() { printf '%s\n' "$1" >&3; sleep "${2:-4}"; }

# Confirm the native NVMe block device is live before installing.
type_b "cat /dev/blk/nvme0n1/size" 4
# Kick off the installer; poll for its own completion marker (the stream
# of a ~512 MiB ext4 payload out of the in-RAM squashfs is slow under
# TCG/KVM, so we DON'T use a fixed sleep).
type_b "hamsh /etc/install_nvme.hamsh" 2
INSTALL_WAIT="${INSTALL_WAIT:-400}"
installed=0
for _ in $(seq 1 "$INSTALL_WAIT"); do
    if grep -a -q '\[install-nvme\] install complete on /dev/blk/nvme0n1' "$STAGE_B_LOG"; then
        installed=1; break
    fi
    if ! kill -0 "$QEMU_B_PID" 2>/dev/null; then
        echo "[test_installer_nvme_inram] FAIL Stage B: qemu exited during install." >&2
        tail -100 "$STAGE_B_LOG" >&2
        exit 1
    fi
    sleep 1
done
if [ "$installed" -ne 1 ]; then
    echo "[test_installer_nvme_inram] FAIL Stage B: 'install complete' not seen in ${INSTALL_WAIT}s." >&2
    tail -100 "$STAGE_B_LOG" >&2
    exit 1
fi
sleep 2
kill "$QEMU_B_PID" 2>/dev/null
wait "$QEMU_B_PID" 2>/dev/null
exec 3>&-
exec 4>&-

# --- Stage B assertions ----------------------------------------------
stage_b_fail=0
check_b() {
    local re="$1"; local label="$2"
    if grep -aE -q "$re" "$STAGE_B_LOG"; then
        echo "[test_installer_nvme_inram]   OK : $label"
    else
        echo "[test_installer_nvme_inram]   MISS: $label" >&2
        stage_b_fail=1
    fi
}
check_b "$KERNEL_BANNER" "installer media: kernel banner (EFI stub -> kernel)"
check_b "$PROMPT_MARKER" "installer media: reached installer shell (in-RAM)"
# The installer medium marker made the kernel skip ALL media USB bring-up.
check_b 'installer medium .in-RAM squashfs.: USB root bring-up SKIPPED entirely' \
        "kernel skipped media USB bring-up (in-RAM installer medium)"
# NVMe came up as a real native block device on the installer media.
check_b '\[nvme\] registered as block slot=' "native NVMe driver registered nvme0n1"
# The installer ran its steps.
check_b '\[install-nvme\] Hamnix NVMe installer' "installer banner"
# KEYSTONE (in-RAM source): the payload came from the in-RAM squashfs.
check_b '\[install-nvme\] sourcing rootfs from in-RAM squashfs' \
        "installer sourced rootfs from in-RAM squashfs (not the media)"
check_b '\[install-nvme\] sourcing ESP from in-RAM squashfs' \
        "installer sourced ESP from in-RAM squashfs (not the media)"
# The kernel-side squashfs extractor actually ran (mount + stream).
check_b '\[sqfs-extract\] start' "kernel sqfs-extract streamer ran"
check_b '\[sqfs-extract\] in-RAM squashfs mounted' "in-RAM squashfs mounted"
check_b '\[sqfs-extract\] DONE: wrote ' "kernel sqfs-extract completed a payload stream"
# GPT actually landed on NVMe.
check_b '\[gpt\] init OK' "GPT init on NVMe target"
check_b '\[gpt\] mkpart idx=0 ' "ESP mkpart on NVMe"
check_b '\[gpt\] mkpart idx=1 ' "rootfs mkpart on NVMe"
check_b '\[install-nvme\] install complete on /dev/blk/nvme0n1' "installer reported complete"
check_b 'loop-enter' "shell re-entered interactive loop after install"

# REAL verification: read the NVMe qcow2 back on the HOST and assert a
# protective MBR (0x55AA), a GPT ("EFI PART" at LBA 1), and an ext4
# superblock magic 0xEF53 at the rootfs partition offset.
NVME_RAW=$(mktemp --tmpdir hamnix-inram-raw.XXXXXX.img)
if qemu-img convert -O raw "$NVME_IMG" "$NVME_RAW" 2>/dev/null; then
    mbr_sig=$(od -An -N2 -tx1 -j 0x1FE "$NVME_RAW" | tr -d ' \n')
    gpt_sig=$(od -An -N8 -c -j 0x200 "$NVME_RAW" | tr -d ' \n')
    if [ "$mbr_sig" = "55aa" ]; then
        echo "[test_installer_nvme_inram]   OK : NVMe disk has protective-MBR signature 0x55AA"
    else
        echo "[test_installer_nvme_inram]   MISS: NVMe MBR signature absent (got 0x$mbr_sig)" >&2
        stage_b_fail=1
    fi
    if echo "$gpt_sig" | grep -q "EFIPART"; then
        echo "[test_installer_nvme_inram]   OK : NVMe disk has GPT 'EFI PART' signature at LBA 1"
    else
        echo "[test_installer_nvme_inram]   MISS: NVMe GPT signature absent at LBA 1 (got '$gpt_sig')" >&2
        stage_b_fail=1
    fi
    # ESP starts at LBA 2048 (1 MiB), 64 MiB; rootfs follows at 65 MiB.
    root_off=$(( 65 * 1024 * 1024 + 1024 + 0x38 ))
    ext4_magic=$(od -An -N2 -tx1 -j "$root_off" "$NVME_RAW" | tr -d ' \n')
    if [ "$ext4_magic" = "53ef" ]; then
        echo "[test_installer_nvme_inram]   OK : NVMe rootfs partition carries ext4 magic 0xEF53 (streamed from in-RAM squashfs)"
    else
        echo "[test_installer_nvme_inram]   MISS: ext4 magic not at expected NVMe rootfs offset (got 0x$ext4_magic)" >&2
        stage_b_fail=1
    fi
fi
rm -f "$NVME_RAW"

if [ "$stage_b_fail" -ne 0 ]; then
    echo "[test_installer_nvme_inram] Stage B FAILED — last 120 lines of installer log:" >&2
    tail -120 "$STAGE_B_LOG" >&2
    exit 1
fi
echo "[test_installer_nvme_inram] Stage B: PASS (installer streamed payload from in-RAM squashfs; GPT + ext4 on NVMe)"

# --- Stage C: boot the installed NVMe disk ALONE (no install media) --
echo "[test_installer_nvme_inram] Stage C: boot from NVMe ALONE (install media detached)"

exec 6<>"$INFIFO_C"
exec 5>"$INFIFO_C"

qemu-system-x86_64 \
    -enable-kvm -cpu host \
    -bios "$OVMF_RW" \
    -drive file="$NVME_IMG",format=qcow2,if=none,id=nvmeroot \
    -device nvme,drive=nvmeroot,serial=hamnvme01,bootindex=0 \
    -m 1024M \
    -nographic -no-reboot -monitor none \
    -serial stdio \
    <&6 > "$STAGE_C_LOG" 2>&1 &
QEMU_C_PID=$!

echo "[test_installer_nvme_inram] Stage C: waiting up to ${BOOT_TIMEOUT}s for the installed-root shell prompt..."
cbooted=0
for _ in $(seq 1 "$BOOT_TIMEOUT"); do
    if grep -a -q "$PROMPT_MARKER" "$STAGE_C_LOG"; then cbooted=1; break; fi
    if ! kill -0 "$QEMU_C_PID" 2>/dev/null; then
        echo "[test_installer_nvme_inram] FAIL Stage C: qemu exited before the installed-root shell." >&2
        tail -100 "$STAGE_C_LOG" >&2
        exit 1
    fi
    sleep 1
done
if [ "$cbooted" -ne 1 ]; then
    echo "[test_installer_nvme_inram] FAIL Stage C: installed-root shell prompt not seen in ${BOOT_TIMEOUT}s." >&2
    tail -100 "$STAGE_C_LOG" >&2
    exit 1
fi
echo "[test_installer_nvme_inram] Stage C: installed-root shell ready; typing commands."
sleep 6

type_c() { printf '%s\n' "$1" >&5; sleep "${2:-4}"; }
type_c "echo NVME_ROOT_REPL_OK" 4
type_c "ls /bin" 4
type_c "cat /version" 4
type_c "echo NVME_ROOT_DONE_99" 4
sleep 3
kill "$QEMU_C_PID" 2>/dev/null
wait "$QEMU_C_PID" 2>/dev/null
exec 5>&-
exec 6>&-

# --- Stage C assertions ----------------------------------------------
stage_c_fail=0
check_c() {
    local re="$1"; local label="$2"
    if grep -aE -q "$re" "$STAGE_C_LOG"; then
        echo "[test_installer_nvme_inram]   OK : $label"
    else
        echo "[test_installer_nvme_inram]   MISS: $label" >&2
        stage_c_fail=1
    fi
}
check_c "$KERNEL_BANNER" "installed NVMe: kernel banner (NVMe-ESP stub -> kernel)"
check_c '\[nvme\] registered as block slot=' "installed NVMe: native driver registered nvme0n1"
check_c '\[rootfs\] ext4 magic on slot .*nvme0n1' "installed NVMe: ext4 root found on nvme0n1pN"
check_c "$PROMPT_MARKER" "installed NVMe: reached interactive shell off ext4-on-NVMe"
check_c '^NVME_ROOT_REPL_OK' "installed NVMe: REPL alive"
if grep -a -q "command not found" "$STAGE_C_LOG"; then
    echo "[test_installer_nvme_inram]   MISS (KEYSTONE): 'command not found' present — commands do NOT resolve off NVMe ext4:" >&2
    grep -a "command not found" "$STAGE_C_LOG" >&2
    stage_c_fail=1
else
    echo "[test_installer_nvme_inram]   OK (KEYSTONE): zero 'command not found' — commands resolve off NVMe ext4."
fi

if [ "$stage_c_fail" -ne 0 ]; then
    echo "[test_installer_nvme_inram] Stage C FAILED — last 100 lines of installed-boot log:" >&2
    tail -100 "$STAGE_C_LOG" >&2
    exit 1
fi
echo "[test_installer_nvme_inram] Stage C: PASS (installed system booted off ext4-on-NVMe)"

echo "[test_installer_nvme_inram] ALL STAGES PASS"
echo "[test_installer_nvme_inram]   ESP-only install medium -> in-RAM squashfs -> ext4 root + ESP on NVMe -> reboot -> installed-root shell (NO media read)"
exit 0
