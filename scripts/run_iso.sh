#!/usr/bin/env bash
# scripts/run_iso.sh — boot build/hamnix.iso interactively under QEMU
# with sane defaults: SLIRP networking (so DHCP gives 10.0.2.15),
# virtio-net NIC, framebuffer console for visible interactive use,
# KVM acceleration if available, and a host-side port forward so
# `ssh -p 2222 user@127.0.0.1` reaches the guest's sshd if one is
# running.
#
# The test scripts under scripts/test_*.sh are headless: -nographic
# serial-stdio, no NIC unless the specific test needs one. This is
# the opposite — it's what you boot when you want to *use* the OS.
#
# Override with env vars:
#   HAMNIX_ISO    path to the ISO (default build/hamnix.iso)
#   HAMNIX_MEM    guest RAM (default 1G)
#   HAMNIX_SMP    guest CPUs (default 2)
#   HAMNIX_GFX    "framebuffer" (default) or "serial" (-nographic
#                 stdio, no graphics, Ctrl-C works as SIGINT to the
#                 foreground guest via the UART path)
#   HAMNIX_SSH_PORT  host port forwarded to guest 22 (default 2222)
#   HAMNIX_KVM    "auto" (default), "on", or "off"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ISO="${HAMNIX_ISO:-build/hamnix.iso}"
MEM="${HAMNIX_MEM:-1G}"
SMP="${HAMNIX_SMP:-2}"
GFX="${HAMNIX_GFX:-framebuffer}"
SSH_PORT="${HAMNIX_SSH_PORT:-2222}"
KVM="${HAMNIX_KVM:-auto}"

if [ ! -f "$ISO" ]; then
    echo "[run_iso] ISO not found: $ISO" >&2
    echo "[run_iso] Build it first: bash scripts/build_iso.sh" >&2
    exit 1
fi

# KVM acceleration is a big quality-of-life win (~10x faster boot,
# usable interactive feel). Auto-detect /dev/kvm + access.
ACCEL=()
case "$KVM" in
    on)   ACCEL=(-accel kvm,thread=multi) ;;
    off)  ACCEL=() ;;
    auto)
        if [ -r /dev/kvm ] && [ -w /dev/kvm ]; then
            ACCEL=(-accel kvm,thread=multi)
        fi
        ;;
esac

# SLIRP user-mode networking: no host privileges needed; QEMU runs a
# built-in DHCP server that hands 10.0.2.15 to the guest and acts as
# the gateway at 10.0.2.2. hostfwd= forwards a host port to the guest
# so an in-guest sshd is reachable from the host.
NET=(
    -netdev "user,id=n0,hostfwd=tcp::${SSH_PORT}-:22"
    -device "virtio-net-pci,netdev=n0,mac=52:54:00:12:34:56"
)

# Two display modes:
#   framebuffer — a QEMU window (-display gtk if available, else sdl).
#                 This is what you want for daily interactive use.
#                 Serial still goes to a separate chardev (a file) so
#                 dmesg / panics are recoverable.
#   serial     — headless -nographic, serial goes to your terminal.
#                 Lets you Ctrl-C the foreground guest task via UART
#                 (the PS/2 path also works after `adce616`).
case "$GFX" in
    framebuffer)
        SERIAL_LOG="$(mktemp -t hamnix-serial-XXXXXX.log)"
        echo "[run_iso] Serial log: $SERIAL_LOG"
        DISPLAY_ARGS=(
            -serial "file:${SERIAL_LOG}"
        )
        ;;
    serial)
        DISPLAY_ARGS=(
            -nographic
            -serial stdio
        )
        ;;
    *)
        echo "[run_iso] HAMNIX_GFX must be 'framebuffer' or 'serial', got: $GFX" >&2
        exit 2
        ;;
esac

echo "[run_iso] Boot: $ISO  RAM=$MEM  SMP=$SMP  KVM=${ACCEL[*]:-off}  GFX=$GFX"
echo "[run_iso] Host -> guest:  ssh -p $SSH_PORT user@127.0.0.1  (if sshd is running)"
echo "[run_iso] Inside hamsh:   ifconfig         # should show 10.0.2.15"
echo "[run_iso] Inside hamsh:   apt update       # SLIRP gives outbound HTTP/HTTPS"
echo

exec qemu-system-x86_64 \
    -cdrom "$ISO" \
    -m "$MEM" \
    -smp "$SMP" \
    "${ACCEL[@]}" \
    "${NET[@]}" \
    "${DISPLAY_ARGS[@]}" \
    -no-reboot
