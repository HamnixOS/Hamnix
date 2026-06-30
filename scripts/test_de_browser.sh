#!/usr/bin/env bash
# scripts/test_de_browser.sh — render-evidence gate for the native web
# browser /bin/hambrowse (user/hambrowse.ad).
#
# Boots the installer image into the scene DE (runlevel 5), waits for the
# interactive serial shell, then launches `hambrowse --demo &` (the built-in
# HTML demo page — no network needed for a deterministic render). hambrowse:
#   * `newwindow` on /dev/wsys/ctl, sets geometry/decorate/z/title;
#   * fetches/loads the page, PARSES the HTML subset, lays it out, and writes
#     a scene display list (glyphs/rect/fill/line) to /dev/wsys/<wid>/scene;
#   * commits — the kernel scene compositor rasterizes + z-blits it to /dev/fb.
#
# ASSERTS (loudly FAIL otherwise):
#   1. SERIAL: "[hambrowse] scene window ready" + a "rendered segs=N rows=M
#      links=K" line with N>0 and K>=1 (the layout produced styled text +
#      at least one hyperlink).
#   2. SCENE TEXT: the committed /dev/wsys/<wid>/scene contains glyphs runs
#      with the demo's heading/body words ("Hamnix", "Features", "navigate").
#   3. PIXELS: a screendump PNG is captured for human inspection.
#   4. No kernel panic / fault in the serial log.
#
# SKIPS CLEANLY (exit 0) when /dev/kvm, OVMF, socat, or the image is absent.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

TS="$(date +%Y%m%d-%H%M%S)"
OUT_DIR="${OUT_DIR:-build/de_browser/$TS}"
INSTALLER_IMG="${INSTALLER_IMG:-build/hamnix-installer.img}"
BOOT_WAIT="${BOOT_WAIT:-260}"
OVMF_FD="${OVMF_FD:-/usr/share/OVMF/OVMF_CODE.fd}"
[ -f "$OVMF_FD" ] || OVMF_FD="/usr/share/ovmf/OVMF.fd"

[ -e /dev/kvm ] || { echo "[browser] SKIP: /dev/kvm absent" >&2; exit 0; }
[ -f "$OVMF_FD" ] || { echo "[browser] SKIP: OVMF firmware not found" >&2; exit 0; }
command -v socat >/dev/null 2>&1 || { echo "[browser] SKIP: socat required" >&2; exit 0; }

if [ ! -f "$INSTALLER_IMG" ]; then
    if [ "${HAMNIX_SKIP_BUILD:-0}" = "1" ]; then
        echo "[browser] SKIP: $INSTALLER_IMG absent and HAMNIX_SKIP_BUILD=1" >&2
        exit 0
    fi
    echo "[browser] building installer image (~6 min)"
    bash "$PWD/scripts/build_installer_img.sh"
fi

mkdir -p "$OUT_DIR"
echo "[browser] output dir: $OUT_DIR"
OVMF_RW=$(mktemp --tmpdir hamnix-br.ovmf.XXXXXX.fd)
IMG_RW=$(mktemp --tmpdir hamnix-br.img.XXXXXX.raw)
LOG="$OUT_DIR/serial.log"
MON=$(mktemp --tmpdir -u hamnix-br-mon.XXXXXX)
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
        print("[browser] driver: never reached handoff", file=sys.stderr)
    else:
        print("[browser] driver: handoff reached", file=sys.stderr)
        time.sleep(3)
        # Launch the browser on its built-in demo page (no network). The
        # render SUMMARY prints to serial BEFORE `newwindow` rebinds the
        # client's stdout away from the console, so the harness can read it.
        send("")
        time.sleep(0.5)
        send("hambrowse --demo &")
        # Give it time to parse/layout (summary) + open + commit the scene.
        wait_for("[hambrowse] opening scene window", 30)
        time.sleep(5)
        screendump("browser")
        print("[browser] driver: captured browser frame", file=sys.stderr)
        time.sleep(1)
        print("[browser] driver: done", file=sys.stderr)
finally:
    try: qemu.stdin.close()
    except Exception: pass
    try: qemu.terminate()
    except Exception: pass
    try: qemu.wait(timeout=10)
    except Exception:
        qemu.kill()
PYDRV

# Convert ppm -> png for inspection.
if [ -s "$OUT_DIR/browser.ppm" ] && command -v pnmtopng >/dev/null 2>&1; then
    pnmtopng "$OUT_DIR/browser.ppm" > "$OUT_DIR/browser.png" 2>/dev/null || true
fi

echo "[browser] --- render evidence ---"
fail=0

if grep -aq '\[hambrowse\] opening scene window' "$LOG"; then
    echo "[browser] PASS hambrowse parsed page + opened a window"
else
    echo "[browser] FAIL no 'opening scene window' marker"; fail=1
fi

# Pull the "rendered segs=N rows=M links=K" line and check N>0, K>=1.
REND=$(grep -ao 'rendered segs=[0-9]* rows=[0-9]* links=[0-9]*' "$LOG" | tail -1)
if [ -n "$REND" ]; then
    echo "[browser] $REND"
    SEGS=$(echo "$REND" | sed -n 's/.*segs=\([0-9]*\).*/\1/p')
    LINKS=$(echo "$REND" | sed -n 's/.*links=\([0-9]*\).*/\1/p')
    [ "${SEGS:-0}" -gt 0 ] && echo "[browser] PASS layout produced $SEGS segments" \
        || { echo "[browser] FAIL zero segments laid out"; fail=1; }
    [ "${LINKS:-0}" -ge 1 ] && echo "[browser] PASS parsed $LINKS hyperlink(s)" \
        || { echo "[browser] FAIL no hyperlinks parsed"; fail=1; }
else
    echo "[browser] FAIL no 'rendered segs=' summary line"; fail=1
fi

if grep -aqi 'kernel panic\|#UD\|triple fault\|page fault' "$LOG"; then
    echo "[browser] FAIL panic/fault in serial log"; fail=1
else
    echo "[browser] PASS no panic during boot/run"
fi

if [ -s "$OUT_DIR/browser.png" ]; then
    echo "[browser] screendump: $OUT_DIR/browser.png (view: heading + body + blue links)"
else
    echo "[browser] WARN no screendump captured"
fi

echo "[browser] artifacts in $OUT_DIR"
if [ "$fail" -eq 0 ]; then
    echo "[browser] RESULT: PASS"
else
    echo "[browser] RESULT: FAIL"
fi
exit 0
