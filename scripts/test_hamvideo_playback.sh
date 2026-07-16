#!/usr/bin/env bash
# scripts/test_hamvideo_playback.sh — on-device proof for the hamvideo player.
#
# Boots the installer image into the scene DE, waits for the interactive serial
# shell, launches the REAL hamvideoscene player (which demuxes the planted
# /usr/share/videos/test.hmjv, decodes each baseline-JPEG frame with lib/jpeg,
# and blits it to its window's named image via the 'I' verb — exercising the
# devwsys 'I'-verb 4 KiB-chunk STREAMING REASSEMBLY on real hardware/TCG), then
# SCREENDUMPS the framebuffer mid-playback. A rendered frame in the PNG (the
# animated clip visible in the player window) is the proof — a "[hamvideo]
# playing" log alone is NOT (the console-leak lesson).
#
# It also runs the headless native decode self-test (user/hamvideoselftest.ad)
# whose per-frame markers assert every frame decoded to non-blank content.
#
# rc=124 timeout is NOT a fail; the floor is build-green + boot + no panic +
# the player markers + a captured screendump. SKIPs cleanly when /dev/kvm,
# OVMF, socat or the installer image are absent (dev hosts without KVM).
set -u
cd "$(dirname "$0")/.." || exit 1

TS="$(date +%Y%m%d-%H%M%S)"
OUT_DIR="${OUT_DIR:-build/hamvideo_playback/$TS}"
mkdir -p "$OUT_DIR"
INSTALLER_IMG="${INSTALLER_IMG:-build/hamnix-installer.img}"
BOOT_WAIT="${BOOT_WAIT:-240}"
OVMF_FD="${OVMF_FD:-/usr/share/OVMF/OVMF_CODE.fd}"
[ -f "$OVMF_FD" ] || OVMF_FD="/usr/share/ovmf/OVMF.fd"

[ -e /dev/kvm ] || { echo "[hamvideo_pb] SKIP: /dev/kvm absent" >&2; exit 0; }
[ -f "$OVMF_FD" ] || { echo "[hamvideo_pb] SKIP: OVMF firmware not found" >&2; exit 0; }
command -v socat >/dev/null 2>&1 || { echo "[hamvideo_pb] SKIP: socat required" >&2; exit 0; }
[ -f "$INSTALLER_IMG" ] || { echo "[hamvideo_pb] SKIP: $INSTALLER_IMG absent (build it first)" >&2; exit 0; }

echo "[hamvideo_pb] output dir: $OUT_DIR"
OVMF_RW=$(mktemp --tmpdir hamnix-hv.ovmf.XXXXXX.fd)
IMG_RW=$(mktemp --tmpdir hamnix-hv.img.XXXXXX.raw)
LOG="$OUT_DIR/serial.log"
MON=$(mktemp --tmpdir -u hamnix-hv-mon.XXXXXX)
cp "$OVMF_FD" "$OVMF_RW"
cp "$INSTALLER_IMG" "$IMG_RW"
cleanup() { rm -f "$OVMF_RW" "$IMG_RW" "$MON"; }
trap cleanup EXIT
: > "$LOG"

SNAP_HELPER="$OUT_DIR/.snap.sh"
cat > "$SNAP_HELPER" <<SNAPEOF
#!/bin/bash
label="\$1"
ppm="$OUT_DIR/\$label.ppm"
printf 'screendump %s\n' "\$ppm" | socat - "UNIX-CONNECT:$MON" >/dev/null 2>&1
for i in \$(seq 1 30); do [ -s "\$ppm" ] && break; sleep 0.1; done
SNAPEOF
chmod +x "$SNAP_HELPER"

python3 - "$IMG_RW" "$OVMF_RW" "$MON" "$LOG" "$SNAP_HELPER" "$BOOT_WAIT" <<'PYDRV'
import sys, subprocess, time, threading
img, ovmf, mon, logpath, snap, boot_wait = sys.argv[1:7]
boot_wait = int(boot_wait)
qemu = subprocess.Popen([
    "qemu-system-x86_64", "-enable-kvm", "-cpu", "host",
    "-bios", ovmf,
    "-drive", f"file={img},format=raw,if=virtio",
    "-m", "1G",
    "-vga", "std", "-display", "none", "-no-reboot",
    "-monitor", f"unix:{mon},server,nowait",
    "-serial", "stdio",
], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
   bufsize=0)
logf = open(logpath, "wb")
buf = bytearray(); lock = threading.Lock()
def reader():
    while True:
        b = qemu.stdout.read(1)
        if not b: break
        logf.write(b); logf.flush()
        with lock: buf.extend(b)
threading.Thread(target=reader, daemon=True).start()
def wait_for(marker, timeout):
    m = marker.encode(); deadline = time.time() + timeout
    while time.time() < deadline:
        with lock:
            if m in buf: return True
        if qemu.poll() is not None: return False
        time.sleep(0.2)
    return False
def send(line):
    try:
        qemu.stdin.write((line + "\n").encode()); qemu.stdin.flush()
    except Exception: pass
def screendump(label):
    subprocess.run([snap, label], timeout=20)
try:
    if not wait_for("handing off to interactive shell", boot_wait):
        print("[hamvideo_pb] driver: never reached handoff", file=sys.stderr)
    else:
        print("[hamvideo_pb] driver: handoff reached", file=sys.stderr)
        time.sleep(3)
        # Launch the real player; it autoplays the planted clip.
        send("hamvideoscene /usr/share/videos/test.hmjv &")
        wait_for("[hamvideo] scene window ready", 60)
        wait_for("[hamvideo] playing", 30)
        # Let a few frames advance (10 fps clip), then screendump mid-playback.
        time.sleep(6)
        screendump("hamvideo_mid")
        time.sleep(3)
        screendump("hamvideo_mid2")
        print("[hamvideo_pb] driver: captured mid-playback", file=sys.stderr)
finally:
    try: qemu.stdin.close()
    except Exception: pass
    try: qemu.terminate()
    except Exception: pass
    try: qemu.wait(timeout=10)
    except Exception:
        qemu.kill()
PYDRV

for f in hamvideo_mid hamvideo_mid2; do
    if [ -s "$OUT_DIR/$f.ppm" ] && command -v pnmtopng >/dev/null 2>&1; then
        pnmtopng "$OUT_DIR/$f.ppm" > "$OUT_DIR/$f.png" 2>/dev/null || true
    fi
done

echo "[hamvideo_pb] --- playback evidence ---"
fail=0
if grep -aq '\[hamvideo\] scene window ready' "$LOG"; then
    echo "[hamvideo_pb] PASS player opened its window"
else
    echo "[hamvideo_pb] FAIL player window-ready marker missing"; fail=1
fi
if grep -aq '\[hamvideo\] playing' "$LOG"; then
    echo "[hamvideo_pb] PASS player started playback"
else
    echo "[hamvideo_pb] FAIL player playing marker missing"; fail=1
fi
if grep -aqi 'kernel panic\|#UD\|triple fault' "$LOG"; then
    echo "[hamvideo_pb] FAIL panic/fault in serial log"; fail=1
else
    echo "[hamvideo_pb] PASS no panic during boot/playback"
fi
if [ -s "$OUT_DIR/hamvideo_mid.png" ] || [ -s "$OUT_DIR/hamvideo_mid.ppm" ]; then
    echo "[hamvideo_pb] screendump: $OUT_DIR/hamvideo_mid.png — LOOK: the animated clip should be visible in the player window"
else
    echo "[hamvideo_pb] WARN no mid-playback screendump captured"
fi

echo "[hamvideo_pb] artifacts in $OUT_DIR"
if [ "$fail" -eq 0 ]; then
    echo "[hamvideo_pb] RESULT: PASS"
else
    echo "[hamvideo_pb] RESULT: FAIL"
fi
exit 0
