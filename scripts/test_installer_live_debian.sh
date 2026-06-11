#!/usr/bin/env bash
# scripts/test_installer_live_debian.sh
#
# REGRESSION GATE (#410 Item 2): a LIVE boot of the first-class
# installer image (NO install performed) brings up the Debian
# namespace entirely from RAM and runs a REAL Debian binary.
#
# What this proves, end to end, on the REAL shipped artifact
# (build/hamnix-installer.img under OVMF — the real boot path):
#
#   1. rc.boot's LIVE branch fires ("booting LIVE environment") because
#      the only disk is the boot medium (install --probe finds no
#      distinct target — the ram/loop/live exclusion in
#      user/install.ad::enumerate_disks keeps the live ramdisk from
#      being offered as an install target).
#   2. The detached live_distro_up spawn drives the kernel's
#      loop_sqfs_live_root: /rootfs.sqfs (firmware-loaded cpio data,
#      NOTHING read from media) -> live-distro.ext4 -> RAM block
#      device `live0` -> ext4 mount -> .hamnix-roots -> #distro named
#      root. Asserted via the "[live-root] DONE" kernel marker.
#   3. `enter linux { ... }` (the rc.boot.full ns recipe, binding
#      '#distro' at enter time) executes a real Debian binary:
#        - /usr/bin/dpkg --version  -> "package management program"
#          (when the host fixture tests/distros/debian-minbase/rootfs
#          was staged into the live image), or
#        - busybox printf assembling LIVE_DEBIAN_OK (busybox-only
#          image) — the typed command line never contains the
#          contiguous marker, so a match is real program OUTPUT.
#
# Judged ONLY by serial-log markers (never wrapper exit codes; a qemu
# timeout after the markers appeared is benign). The first serial
# command after boot is historically dropped, so every command is
# RE-SENT until its own output appears (feedback_serial_test_first_cmd
# _dropped) and keystrokes are gated on boot markers, not fixed sleeps.
#
# SKIPS CLEANLY (exit 0) when /dev/kvm, OVMF, or the installer image is
# unavailable and cannot be built, and when the live image carries
# neither dpkg nor busybox (host without any fixtures).
#
# Env overrides:
#   INSTALLER_IMG      image path     (default: build/hamnix-installer.img)
#   LIVE_DISTRO_IMG    live ext4 path (default: build/hamnix-live-distro.img)
#   OVMF_FD            OVMF firmware  (default: auto-resolved)
#   BOOT_WAIT          seconds to wait for boot markers   (default: 240)
#   CMD_WAIT           seconds to wait for command output (default: 180)
#   QEMU_MEM           guest RAM      (default: 1G — the ship command)
#   HAMNIX_SKIP_BUILD  1 = require an existing image (no rebuild)
#   KEEP_LOGS          1 = keep the serial log on PASS

set -uo pipefail

PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

INSTALLER_IMG="${INSTALLER_IMG:-build/hamnix-installer.img}"
LIVE_DISTRO_IMG="${LIVE_DISTRO_IMG:-build/hamnix-live-distro.img}"
BOOT_WAIT="${BOOT_WAIT:-240}"
CMD_WAIT="${CMD_WAIT:-180}"
QEMU_MEM="${QEMU_MEM:-1G}"
TAG="[test_live_debian]"

LIVE_MARKER="booting LIVE environment"
HANDOFF_MARKER="handing off to interactive shell"
LIVEROOT_MARKER="[live-root] DONE"

# --- environment gates (skip cleanly) ---------------------------------
if [ ! -e /dev/kvm ]; then
    echo "$TAG SKIP: /dev/kvm absent (KVM required for the interactive OVMF boot)" >&2
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
    echo "$TAG SKIP: OVMF firmware not found (apt install ovmf)" >&2
    exit 0
fi

# --- ensure the installer image exists --------------------------------
if [ ! -f "$INSTALLER_IMG" ]; then
    if [ "${HAMNIX_SKIP_BUILD:-0}" = "1" ]; then
        echo "$TAG SKIP: $INSTALLER_IMG absent and HAMNIX_SKIP_BUILD=1." >&2
        exit 0
    fi
    echo "$TAG installer image absent; building via build_installer_img.sh (~6 min)"
    bash "$PROJ_ROOT/scripts/build_installer_img.sh"
fi
if [ ! -f "$INSTALLER_IMG" ]; then
    echo "$TAG SKIP: $INSTALLER_IMG unavailable (build gated)." >&2
    exit 0
fi

# --- decide the in-guest probe by what the live image really carries --
# debugfs (e2fsprogs) lists the live ext4 without mounting. The live
# image's #distro subtree is distro/ at the partition root.
HAVE_DPKG=0
HAVE_BUSYBOX=0
DEBUGFS="/sbin/debugfs"; [ -x "$DEBUGFS" ] || DEBUGFS="$(command -v debugfs || true)"
if [ -f "$LIVE_DISTRO_IMG" ] && [ -n "$DEBUGFS" ]; then
    if "$DEBUGFS" -R "stat /distro/usr/bin/dpkg" "$LIVE_DISTRO_IMG" 2>/dev/null \
            | grep -q "Type: regular"; then
        HAVE_DPKG=1
    fi
    if "$DEBUGFS" -R "stat /distro/bin/busybox" "$LIVE_DISTRO_IMG" 2>/dev/null \
            | grep -q "Type: regular"; then
        HAVE_BUSYBOX=1
    fi
fi
if [ "$HAVE_DPKG" -eq 0 ] && [ "$HAVE_BUSYBOX" -eq 0 ]; then
    if [ ! -f "$LIVE_DISTRO_IMG" ] || [ -z "$DEBUGFS" ]; then
        echo "$TAG NOTE: cannot inspect $LIVE_DISTRO_IMG (missing image or debugfs);"
        echo "$TAG       falling back to the kernel live-root marker assertions only."
    else
        echo "$TAG SKIP: live image carries neither dpkg nor busybox (no host fixtures:"
        echo "$TAG       tests/distros/debian-minbase/rootfs, tests/u-binary/u_busybox_musl)."
        exit 0
    fi
fi
echo "$TAG live image probe: dpkg=$HAVE_DPKG busybox=$HAVE_BUSYBOX"

OVMF_RW=$(mktemp --tmpdir hamnix-live-deb.ovmf.XXXXXX.fd)
IMG_RW=$(mktemp --tmpdir hamnix-live-deb.img.XXXXXX.raw)
LOG=$(mktemp --tmpdir hamnix-live-deb.XXXXXX.log)
FIFO=$(mktemp --tmpdir -u hamnix-live-deb-in.XXXXXX)
mkfifo "$FIFO"
cp "$OVMF_FD" "$OVMF_RW"
# Fresh writable COPY of the image (never mutate the shipped artifact).
cp "$INSTALLER_IMG" "$IMG_RW"

cleanup() {
    [ -n "${QEMU_PID:-}" ] && kill "$QEMU_PID" 2>/dev/null
    exec 3>&- 2>/dev/null
    rm -f "$OVMF_RW" "$IMG_RW" "$FIFO"
}
trap cleanup EXIT

# Ship command shape (-enable-kvm -cpu host -bios OVMF -drive raw/virtio
# -m 1G -vga std -serial stdio -no-reboot) with -display none for a
# headless run and stdin fed from a FIFO so we can type at hamsh.
qemu-system-x86_64 \
    -enable-kvm -cpu host \
    -bios "$OVMF_RW" \
    -drive file="$IMG_RW",format=raw,if=virtio \
    -m "$QEMU_MEM" \
    -vga std -display none -no-reboot \
    -monitor none \
    -serial stdio \
    < "$FIFO" > "$LOG" 2>&1 &
QEMU_PID=$!
# Keep the FIFO write end open for the whole run (fd 3); otherwise the
# first writer's close would EOF qemu's stdin.
exec 3> "$FIFO"

wait_for() {
    # wait_for <pattern> <seconds> — poll the serial log.
    local pat="$1" secs="$2" i
    for i in $(seq 1 "$secs"); do
        if grep -a -q "$pat" "$LOG"; then
            return 0
        fi
        if ! kill -0 "$QEMU_PID" 2>/dev/null; then
            return 1
        fi
        sleep 1
    done
    return 1
}

send_until() {
    # send_until <command> <output-pattern> <total-seconds>
    # Repeatedly type <command> (freshly-booted hamsh drops the first
    # serial line) until <output-pattern> appears in the log.
    local cmd="$1" pat="$2" secs="$3"
    local waited=0
    while [ "$waited" -lt "$secs" ]; do
        printf '%s\n' "$cmd" >&3
        local i
        for i in $(seq 1 15); do
            if grep -a -q "$pat" "$LOG"; then
                return 0
            fi
            if ! kill -0 "$QEMU_PID" 2>/dev/null; then
                return 1
            fi
            sleep 1
            waited=$((waited + 1))
            [ "$waited" -ge "$secs" ] && break
        done
    done
    grep -a -q "$pat" "$LOG"
}

fail=0

# --- boot markers ------------------------------------------------------
echo "$TAG waiting up to ${BOOT_WAIT}s for the LIVE branch + handoff..."
if wait_for "$LIVE_MARKER" "$BOOT_WAIT"; then
    echo "$TAG PASS: rc.boot took the LIVE branch ('$LIVE_MARKER')."
else
    echo "$TAG FAIL: LIVE-branch marker not seen — did install --probe wrongly find a target (live-image self-clobber)?" >&2
    tail -80 "$LOG" | strings >&2
    exit 1
fi

if wait_for "$LIVEROOT_MARKER" "$BOOT_WAIT"; then
    echo "$TAG PASS: kernel live-root bringup completed ('$LIVEROOT_MARKER')."
else
    echo "$TAG FAIL: '[live-root] DONE' not seen — sqfs_live_root extraction/mount/#distro failed." >&2
    grep -a "live-root\|live_distro_up" "$LOG" | tail -20 >&2
    tail -40 "$LOG" | strings >&2
    fail=1
fi

if wait_for "$HANDOFF_MARKER" "$BOOT_WAIT"; then
    echo "$TAG PASS: interactive handoff reached."
else
    echo "$TAG FAIL: handoff marker not seen in ${BOOT_WAIT}s." >&2
    tail -80 "$LOG" | strings >&2
    exit 1
fi

# --- run a real Debian binary inside `enter linux { ... }` -------------
if [ "$fail" -eq 0 ]; then
    if [ "$HAVE_DPKG" -eq 1 ]; then
        # Real Debian dpkg: the version banner is program OUTPUT — the
        # typed command never contains "package management program".
        if send_until "enter linux { /usr/bin/dpkg --version }" \
                      "package management program" "$CMD_WAIT"; then
            echo "$TAG PASS: real Debian dpkg ran in the live linux ns (version banner seen)."
        else
            echo "$TAG FAIL: dpkg version banner not seen — real Debian binary did not run." >&2
            fail=1
        fi
    else
        # Busybox-only image: assemble the marker from two printf args so
        # the typed line never contains the contiguous string.
        if send_until "enter linux { /bin/printf %s%s\\\\n LIVE_DEB IAN_OK }" \
                      "LIVE_DEBIAN_OK" "$CMD_WAIT"; then
            echo "$TAG PASS: busybox printf ran in the live linux ns (LIVE_DEBIAN_OK assembled)."
        else
            echo "$TAG FAIL: busybox marker not assembled — live linux ns did not execute." >&2
            fail=1
        fi
    fi
fi

# No real panic on the way up (the benign uaccess-smoke "EFAULT (no
# panic)" string is excluded).
if grep -a -E "KERNEL PANIC|PANIC:" "$LOG" | grep -av "no panic" | grep -aq .; then
    echo "$TAG FAIL: kernel panic during the live boot:" >&2
    grep -a -E "KERNEL PANIC|PANIC:" "$LOG" | grep -av "no panic" | head >&2
    fail=1
fi

kill "$QEMU_PID" 2>/dev/null
wait "$QEMU_PID" 2>/dev/null

if [ "$fail" -eq 0 ]; then
    echo "$TAG PASS"
    [ "${KEEP_LOGS:-0}" = "1" ] || rm -f "$LOG"
    exit 0
else
    echo "$TAG FAIL (serial log: $LOG)" >&2
    exit 1
fi
