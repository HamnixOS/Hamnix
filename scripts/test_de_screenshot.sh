#!/usr/bin/env bash
# scripts/test_de_screenshot.sh — boot the installer image, wait for the
# DE to come up, screendump the GOP framebuffer to a PNG the orchestrator
# can READ.
#
# The user's #1 DE complaint: it LOOKS broken. The orchestrator has visual
# input — this script gives it the artifact to look at:
#
#   build/de_screenshot.png   PNG of the live framebuffer just after the
#                             DE autostart marker fires.
#
# Boots build/hamnix-installer.img under OVMF/KVM matching the user's ship
# command (mirrors scripts/test_installer_de_runlevel5.sh), waits for the
# rc.5 "hamUI stack started by supervisor" marker (or a fallback timer),
# sleeps to let the desktop paint, then issues `screendump` to the QEMU
# monitor and converts the resulting PPM to PNG.
#
# Skips cleanly (exit 0) when /dev/kvm, OVMF, the installer image, or a
# PPM->PNG converter is unavailable. The screenshot itself is the
# deliverable; this script INTENTIONALLY does NOT assert "the DE looks
# right" — the orchestrator reads the PNG and judges that visually.
#
# Env overrides:
#   INSTALLER_IMG      image path        (default: build/hamnix-installer.img)
#   OVMF_FD            OVMF firmware     (default: auto-resolved)
#   BOOT_WAIT          seconds to wait for the handoff marker (default: 240)
#   PAINT_WAIT         extra seconds to let the DE paint (default: 8)
#   SHOT_OUT           output PNG path   (default: build/de_screenshot.png)
#   HAMNIX_SKIP_BUILD  1 = require an existing image (no rebuild)

set -uo pipefail

PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

INSTALLER_IMG="${INSTALLER_IMG:-build/hamnix-installer.img}"
BOOT_WAIT="${BOOT_WAIT:-240}"
PAINT_WAIT="${PAINT_WAIT:-8}"
SHOT_OUT="${SHOT_OUT:-build/de_screenshot.png}"
HANDOFF_MARKER="handing off to interactive shell"

# --- environment gates (skip cleanly) ---------------------------------
if [ ! -e /dev/kvm ]; then
    echo "[test_de_screenshot] SKIP: /dev/kvm absent (KVM required for -vga std OVMF boot)" >&2
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
    echo "[test_de_screenshot] SKIP: OVMF firmware not found (apt install ovmf)" >&2
    exit 0
fi

# screendump produces PPM; we need a PPM->PNG converter for the
# deliverable. Try convert (ImageMagick), then ffmpeg, then pnmtopng.
CONVERTER=""
if command -v convert >/dev/null 2>&1; then
    CONVERTER="convert"
elif command -v ffmpeg >/dev/null 2>&1; then
    CONVERTER="ffmpeg"
elif command -v pnmtopng >/dev/null 2>&1; then
    CONVERTER="pnmtopng"
else
    echo "[test_de_screenshot] SKIP: no PPM->PNG converter (need convert/ffmpeg/pnmtopng)" >&2
    exit 0
fi

# Need a monitor driver to issue screendump headlessly.
MON_DRIVER=""
if command -v socat >/dev/null 2>&1; then
    MON_DRIVER="socat"
elif command -v nc >/dev/null 2>&1; then
    MON_DRIVER="nc"
else
    echo "[test_de_screenshot] SKIP: no socat/nc to drive QEMU monitor" >&2
    exit 0
fi

# --- ensure the installer image exists --------------------------------
if [ ! -f "$INSTALLER_IMG" ]; then
    if [ "${HAMNIX_SKIP_BUILD:-0}" = "1" ]; then
        echo "[test_de_screenshot] SKIP: $INSTALLER_IMG absent and HAMNIX_SKIP_BUILD=1." >&2
        exit 0
    fi
    echo "[test_de_screenshot] installer image absent; building via build_installer_img.sh (~6 min)"
    bash "$PROJ_ROOT/scripts/build_installer_img.sh"
fi
if [ ! -f "$INSTALLER_IMG" ]; then
    echo "[test_de_screenshot] SKIP: $INSTALLER_IMG unavailable (build gated)." >&2
    exit 0
fi

OVMF_RW=$(mktemp --tmpdir hamnix-de-shot.ovmf.XXXXXX.fd)
IMG_RW=$(mktemp --tmpdir hamnix-de-shot.img.XXXXXX.raw)
LOG=$(mktemp --tmpdir hamnix-de-shot.XXXXXX.log)
MON=$(mktemp --tmpdir -u hamnix-de-shot-mon.XXXXXX)
SHOT_PPM=$(mktemp --tmpdir hamnix-de-shot.XXXXXX.ppm)
cp "$OVMF_FD" "$OVMF_RW"
cp "$INSTALLER_IMG" "$IMG_RW"

QEMU_PID=""
cleanup() {
    [ -n "$QEMU_PID" ] && kill "$QEMU_PID" 2>/dev/null
    rm -f "$OVMF_RW" "$IMG_RW" "$MON" "$SHOT_PPM"
}
trap cleanup EXIT

mkdir -p "$(dirname "$SHOT_OUT")"

# Mirror the user's exact ship command, headlessly with a monitor socket.
qemu-system-x86_64 \
    -enable-kvm -cpu host \
    -bios "$OVMF_RW" \
    -drive file="$IMG_RW",format=raw,if=virtio \
    -m "${HAMNIX_VM_MEM:-2G}" \
    -vga std -display none -no-reboot \
    -monitor "unix:$MON,server,nowait" \
    -serial stdio \
    > "$LOG" 2>&1 < /dev/null &
QEMU_PID=$!

echo "[test_de_screenshot] waiting up to ${BOOT_WAIT}s for handoff marker..."
booted=0
for _ in $(seq 1 "$BOOT_WAIT"); do
    if grep -a -q "$HANDOFF_MARKER" "$LOG"; then
        booted=1
        break
    fi
    if ! kill -0 "$QEMU_PID" 2>/dev/null; then
        echo "[test_de_screenshot] FAIL: qemu exited before reaching the handoff marker." >&2
        tail -80 "$LOG" >&2
        exit 1
    fi
    sleep 1
done
if [ "$booted" -ne 1 ]; then
    echo "[test_de_screenshot] FAIL: handoff marker not seen in ${BOOT_WAIT}s." >&2
    tail -80 "$LOG" >&2
    exit 1
fi
echo "[test_de_screenshot] handoff reached; letting the DE paint for ${PAINT_WAIT}s."
sleep "$PAINT_WAIT"

mon_cmd() {
    if [ "$MON_DRIVER" = "socat" ]; then
        printf '%s\n' "$1" | socat - "UNIX-CONNECT:$MON" >/dev/null 2>&1
    else
        printf '%s\n' "$1" | nc -U -q1 "$MON" >/dev/null 2>&1
    fi
}

if ! mon_cmd "screendump $SHOT_PPM"; then
    echo "[test_de_screenshot] FAIL: monitor screendump command failed." >&2
    exit 1
fi
sleep 2

kill "$QEMU_PID" 2>/dev/null
wait "$QEMU_PID" 2>/dev/null
QEMU_PID=""

if [ ! -s "$SHOT_PPM" ]; then
    echo "[test_de_screenshot] FAIL: screendump produced empty PPM." >&2
    exit 1
fi

case "$CONVERTER" in
    convert)
        convert "$SHOT_PPM" "$SHOT_OUT" 2>/dev/null
        ;;
    ffmpeg)
        ffmpeg -y -loglevel error -i "$SHOT_PPM" "$SHOT_OUT" </dev/null
        ;;
    pnmtopng)
        pnmtopng "$SHOT_PPM" > "$SHOT_OUT" 2>/dev/null
        ;;
esac

if [ ! -s "$SHOT_OUT" ]; then
    echo "[test_de_screenshot] FAIL: PPM->PNG conversion ($CONVERTER) produced empty $SHOT_OUT." >&2
    exit 1
fi

size=$(wc -c < "$SHOT_OUT")
echo "[test_de_screenshot] PASS: wrote $SHOT_OUT ($size bytes) via $CONVERTER."
rm -f "$LOG"
exit 0
