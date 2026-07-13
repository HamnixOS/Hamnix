#!/usr/bin/env bash
# run_installer.sh — boot the Hamnix installer image in QEMU, correctly.
#
# WHY THIS EXISTS
# ---------------
# The installer is EFI-booted under OVMF. OVMF only auto-launches a disk's
# \EFI\BOOT\BOOTX64.EFI when that disk is its chosen boot candidate. The moment
# you also attach a blank NVMe target and/or a NIC (which you MUST, to install
# to and to get networking), OVMF's boot-device selection stops picking the
# installer media — it falls through to the EFI Internal Shell, or, if a NIC is
# present, to PXE network boot. The cure is an EXPLICIT `bootindex=0` on the
# installer media so OVMF always boots it first. A read-only system OVMF also
# can't persist its boot vars, so we boot a WRITABLE copy. This script sets both
# up (plus a blank NVMe install target and a user-mode NIC) so the installer
# "just boots" — then you run `/etc/install_nvme.hamsh` inside it to install to
# the NVMe, power off, and boot the installed disk with scripts/_installed_boot.sh.
#
# USAGE
#   bash scripts/run_installer.sh                 # GTK window, KVM if available
#   HEADLESS=1 bash scripts/run_installer.sh      # no window; serial on stdio
#   DISK=/path/target.qcow2 bash scripts/run_installer.sh   # persist the install
#
# KNOBS (env)
#   IMG        installer image           (default: build/hamnix-installer.img; built if absent)
#   DISK       NVMe install target       (default: /tmp/hamnix-install-target.qcow2, 16G, created if absent)
#   MEM        guest RAM                  (default: 2G)
#   OVMF_FD    OVMF firmware              (auto-resolved)
#   HEADLESS   1 => -display none + -serial stdio (default: GTK window + serial to a log)
#   NO_NET     1 => omit the NIC          (default: user-mode virtio-net attached)
#   NO_KVM     1 => force TCG             (default: KVM when /dev/kvm exists)
set -euo pipefail
cd "$(dirname "$0")/.."

IMG="${IMG:-build/hamnix-installer.img}"
DISK="${DISK:-/tmp/hamnix-install-target.qcow2}"
MEM="${MEM:-2G}"

say() { echo "[run_installer] $*"; }

# --- installer image (build on demand) --------------------------------------
if [ ! -f "$IMG" ]; then
    say "installer image $IMG absent — building via scripts/build_installer_img.sh (~14 min)"
    HAMNIX_INSTALLER_IMG_OUT="$IMG" bash scripts/build_installer_img.sh
fi
[ -f "$IMG" ] || { say "FAIL: $IMG still missing after build."; exit 1; }

# --- OVMF firmware (writable copy so UEFI can persist boot vars) -------------
if [ -z "${OVMF_FD:-}" ]; then
    for c in /usr/share/ovmf/OVMF.fd /usr/share/OVMF/OVMF_CODE.fd /usr/share/OVMF/OVMF_CODE_4M.fd; do
        [ -f "$c" ] && { OVMF_FD="$c"; break; }
    done
fi
{ [ -n "${OVMF_FD:-}" ] && [ -f "$OVMF_FD" ]; } || { say "FAIL: OVMF firmware not found (apt install ovmf)."; exit 1; }
OVMF_RW=$(mktemp --tmpdir hamnix-installer.ovmf.XXXXXX.fd)
cp "$OVMF_FD" "$OVMF_RW"

# --- blank NVMe install target ----------------------------------------------
if [ ! -f "$DISK" ]; then
    say "creating a blank 16G NVMe install target at $DISK"
    qemu-img create -f qcow2 "$DISK" 16G >/dev/null
fi

cleanup() { rm -f "$OVMF_RW"; }
trap cleanup EXIT

# --- accel / display / net --------------------------------------------------
ACCEL=(); if [ -z "${NO_KVM:-}" ] && [ -e /dev/kvm ]; then ACCEL=(-enable-kvm -cpu host); else ACCEL=(-cpu qemu64); say "no /dev/kvm (or NO_KVM set): TCG — boot will be slow"; fi

NET=(); if [ -z "${NO_NET:-}" ]; then NET=(-netdev user,id=hnet0 -device virtio-net-pci,netdev=hnet0); fi

DISPLAY_ARGS=(); LOG=""
if [ -n "${HEADLESS:-}" ]; then
    DISPLAY_ARGS=(-display none -serial stdio)
else
    LOG=$(mktemp --tmpdir hamnix-installer.serial.XXXXXX.log)
    DISPLAY_ARGS=(-vga std -display gtk -serial "file:$LOG")
    say "serial log: $LOG"
fi

say "media=$IMG  target=$DISK  mem=$MEM  accel=${ACCEL[*]}"
say "inside the guest: run  /etc/install_nvme.hamsh  to install to the NVMe target."

# The installer media carries \EFI\BOOT\BOOTX64.EFI; bootindex=0 forces OVMF to
# boot it even with the NVMe target + NIC present (otherwise -> EFI shell / PXE).
exec qemu-system-x86_64 \
    "${ACCEL[@]}" \
    -m "$MEM" \
    -bios "$OVMF_RW" \
    -drive "file=$IMG,format=raw,if=none,id=instmedia" \
    -device virtio-blk-pci,drive=instmedia,bootindex=0 \
    -device nvme,drive=nvmetgt,serial=hamtgt01 \
    -drive "file=$DISK,format=qcow2,if=none,id=nvmetgt" \
    "${NET[@]}" \
    "${DISPLAY_ARGS[@]}" \
    -no-reboot \
    -monitor none
