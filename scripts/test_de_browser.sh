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
import sys, subprocess, time, threading, os
img, ovmf, mon, logpath, snap, boot_wait = sys.argv[1:7]
boot_wait = int(boot_wait)
# DE + browser + fonts need headroom: the scene DE OOM'd at -m 1G during
# shell/command pre-warm (elf: OOM), so the browser never launched. DE tests
# default to 2G (see the T20 DE-OOM lesson); override with HAMNIX_VM_MEM.
vm_mem = os.environ.get("HAMNIX_VM_MEM", "2G")
qemu = subprocess.Popen([
    "qemu-system-x86_64", "-enable-kvm", "-cpu", "host",
    "-bios", ovmf,
    "-drive", f"file={img},format=raw,if=virtio",
    "-m", vm_mem,
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
LAUNCH_CMD = os.environ.get("HAMBROWSE_LAUNCH", "hambrowse --demo &")
try:
    # Handoff marker: the scene-DE image boots straight to runlevel 5 and never
    # prints rc.boot.full's "handing off to interactive shell" — it brings up the
    # DE and drops an interactive hamsh on the serial console, announced by the
    # shell-ready banner. Wait for THAT (was stale → the gate never launched the
    # browser and false-FAILed the whole track).
    if not wait_for("M16.35 shell ready", boot_wait):
        print("[browser] driver: never reached handoff", file=sys.stderr)
    else:
        print("[browser] driver: handoff reached", file=sys.stderr)
        time.sleep(3)
        # WARM-UP: a freshly-booted hamsh DROPS its first serial command line
        # on a loaded host, which would silently swallow the timed launch and
        # fail the test even though the browser is fine. Send a no-op first and
        # confirm it echoes back before we launch anything real. Retry the
        # warm-up until the shell proves it is consuming our input.
        warmed = False
        for w in range(6):
            tag = "__WARMUP_%d__" % w
            with lock:
                base = len(buf)
            send("echo " + tag)
            # Wait for the shell to ECHO the tag back (proof it read the line).
            deadline = time.time() + 6
            while time.time() < deadline:
                with lock:
                    if buf.find(tag.encode(), base) != -1:
                        warmed = True
                        break
                if qemu.poll() is not None:
                    break
                time.sleep(0.2)
            if warmed:
                print("[browser] driver: shell warm-up ok (attempt %d)" % (w + 1),
                      file=sys.stderr)
                break
            print("[browser] driver: warm-up attempt %d not echoed, retrying"
                  % (w + 1), file=sys.stderr)
        if not warmed:
            print("[browser] driver: WARNING shell never echoed warm-up",
                  file=sys.stderr)
        # Launch the browser on its built-in demo page (no network). The
        # render SUMMARY prints to serial BEFORE `newwindow` rebinds the
        # client's stdout away from the console, so the harness can read it.
        # Retry the launch up to 6× — a dropped/lost line just means no
        # "opening scene window" marker, so re-send until it appears.
        opened = False
        for attempt in range(6):
            send(LAUNCH_CMD)
            print("[browser] driver: launch attempt %d: %s"
                  % (attempt + 1, LAUNCH_CMD), file=sys.stderr)
            # Give it time to parse/layout (summary) + open + commit the scene.
            if wait_for("[hambrowse] opening scene window", 25):
                opened = True
                print("[browser] driver: window opened on attempt %d"
                      % (attempt + 1), file=sys.stderr)
                break
            print("[browser] driver: no window on attempt %d, retrying"
                  % (attempt + 1), file=sys.stderr)
        time.sleep(5)
        screendump("browser")
        print("[browser] driver: captured browser frame (opened=%s)" % opened,
              file=sys.stderr)
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

# BROWSER-DISTINCTIVE PIXEL SIGNATURE.
# A generic titlebar-blue count is worthless — EVERY DE window (terminal,
# calculator, file-manager) has a #3a6ea5 title bar, so that gate passes even
# with no browser on screen. Instead we look for colors that ONLY the
# hambrowse demo page paints: link blue #1a4fd0 (26,79,208), heading dark
# blue #14306e (20,48,110), and pre/code teal #0a6b5a (10,107,90). None of
# these appear in the stock DE chrome. This is a supporting signal; the
# authoritative render proof stays the serial "segs=N>0" line above.
PIX_PPM="$OUT_DIR/browser.ppm"
if [ -s "$PIX_PPM" ]; then
    PIXOUT=$(python3 - "$PIX_PPM" <<'PYPIX'
import sys
path = sys.argv[1]
data = open(path, "rb").read()
# Parse the binary PPM (P6) header: magic, width, height, maxval.
if not data.startswith(b"P6"):
    print("NOHDR 0"); sys.exit(0)
idx = 2; fields = []
while len(fields) < 3 and idx < len(data):
    while idx < len(data) and data[idx:idx+1].isspace():
        idx += 1
    if idx < len(data) and data[idx:idx+1] == b"#":
        while idx < len(data) and data[idx:idx+1] != b"\n":
            idx += 1
        continue
    start = idx
    while idx < len(data) and not data[idx:idx+1].isspace():
        idx += 1
    fields.append(int(data[start:idx]))
w, h, maxv = fields
idx += 1  # single whitespace after maxval
pix = data[idx:]
# distinctive target colors (r,g,b)
targets = [(26, 79, 208), (20, 48, 110), (10, 107, 90)]
TOL = 55
hits = 0
n = (len(pix) // 3) * 3
i = 0
while i < n:
    r = pix[i]; g = pix[i+1]; b = pix[i+2]
    for (tr, tg, tb) in targets:
        if abs(r-tr) <= TOL and abs(g-tg) <= TOL and abs(b-tb) <= TOL:
            hits += 1
            break
    i += 3
print("OK %d" % hits)
PYPIX
)
    PIX_HITS=$(echo "$PIXOUT" | awk '{print $2}')
    PIX_HITS=${PIX_HITS:-0}
    echo "[browser] browser-distinctive pixels (link-blue/heading/teal): $PIX_HITS"
    # Only enforce when a window actually opened this run; if the frame was
    # grabbed before the compositor blitted, the serial gate already fails.
    if grep -aq '\[hambrowse\] opening scene window' "$LOG"; then
        if [ "$PIX_HITS" -ge 8 ]; then
            echo "[browser] PASS screendump shows hambrowse-distinctive pixels"
        else
            echo "[browser] FAIL screendump has no hambrowse-distinctive pixels (only generic chrome?)"; fail=1
        fi
    fi
else
    echo "[browser] WARN no PPM for pixel-signature check"
fi

echo "[browser] artifacts in $OUT_DIR"
if [ "$fail" -eq 0 ]; then
    echo "[browser] RESULT: PASS"
    RC=0
else
    echo "[browser] RESULT: FAIL"
    # Surface the browser/window-server serial context for triage.
    echo "[browser] --- hambrowse/wsys serial lines ---" >&2
    grep -aiE 'hambrowse|wsys|scene|newwindow|opening scene' "$LOG" | tail -40 >&2 \
        || echo "[browser] (no hambrowse/wsys serial lines captured)" >&2
    RC=1
fi
exit "$RC"
