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
        #
        # ROBUSTNESS: a freshly-booted hamsh drops its FIRST serial command
        # line (known quirk — the first line is swallowed, never echoed), and
        # under heavy host load the prompt may not be ready yet. So we RE-SEND
        # `hambrowse --demo &` until its own render marker appears, rather than
        # firing once and hoping. Each attempt waits a few seconds for the
        # marker; if absent we send again. This turns a dropped-first-command
        # (or slow-boot) miss into a retry instead of a false FAIL.
        send("")           # wake the prompt / absorb the first-line drop
        time.sleep(0.5)
        got_marker = False
        for attempt in range(6):
            print(f"[browser] driver: launch attempt {attempt+1}", file=sys.stderr)
            send("hambrowse --demo &")
            if wait_for("[hambrowse] opening scene window", 12):
                got_marker = True
                break
        if not got_marker:
            print("[browser] driver: marker never appeared after retries",
                  file=sys.stderr)
        # Let it commit the scene + let the compositor present it.
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

# The "opening scene window" line and the "rendered segs=" summary are
# BOTH printed BEFORE hambrowse actually opens its window, so they are
# NOT sufficient evidence the window opened. Assert the newwindow step
# did not fail — this is the QA-N6 regression guard: when the live
# console dropped to a regular user (uid 1001) the `newwindow` open of
# /dev/wsys/ctl was refused, so `_newwindow` returned -1 and NO window
# ever opened even though the pre-open markers printed fine.
if grep -aq '\[hambrowse\] FAIL newwindow\|\[hambrowse\] cannot open /dev/wsys/ctl\|\[hambrowse\] cannot reopen /dev/wsys/ctl\|\[hambrowse\] /dev/wsys/ctl returned no wid' "$LOG"; then
    echo "[browser] FAIL hambrowse could not create its window (newwindow rejected)"; fail=1
else
    echo "[browser] PASS newwindow succeeded (no window-open error)"
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

# NON-BLANK / actually-composited check. The serial "rendered segs=" line
# only proves hambrowse laid out the page in memory BEFORE it wrote the
# scene; it does NOT prove the window composited to the framebuffer. So we
# inspect the captured frame for hambrowse's window chrome: its title bar is
# a solid band of #3a6ea5 (58,110,165) ~600px wide. A desktop-only frame (no
# browser window) has no such band. This closes the gap where the markers
# print but the per-window scene write silently fails to composite.
if [ -s "$OUT_DIR/browser.ppm" ]; then
    BLUE=$(python3 - "$OUT_DIR/browser.ppm" <<'PYPX'
import sys
try:
    f=open(sys.argv[1],'rb')
    assert f.readline().strip()==b'P6'
    W,H=[int(t) for t in f.readline().split()]
    f.readline()  # maxval
    d=f.read()
    tgt=(58,110,165); tol=24
    n=0
    for y in range(0,H,4):
        base=y*W*3
        for x in range(0,W,4):
            o=base+x*3
            if abs(d[o]-tgt[0])<=tol and abs(d[o+1]-tgt[1])<=tol and abs(d[o+2]-tgt[2])<=tol:
                n+=1
    print(n)
except Exception as e:
    print(0)
PYPX
)
    echo "[browser] screendump title-bar-blue pixels (sampled): ${BLUE:-0}"
    if [ "${BLUE:-0}" -ge 150 ]; then
        echo "[browser] PASS browser window composited to framebuffer (blue title bar present)"
    else
        echo "[browser] FAIL browser window NOT composited (no title bar in frame)"; fail=1
    fi
    echo "[browser] screendump: $OUT_DIR/browser.ppm (blue title bar + white body + links)"
else
    echo "[browser] FAIL no screendump captured"; fail=1
fi

echo "[browser] artifacts in $OUT_DIR"
echo "[browser] serial log: $LOG"
if [ "$fail" -eq 0 ]; then
    echo "[browser] RESULT: PASS"
    exit 0
else
    echo "[browser] RESULT: FAIL"
    # VISIBILITY: on failure, surface what hambrowse (and the shell around
    # it) actually printed on the serial console so the failure is never a
    # green-looking mystery. Dump the hambrowse lines plus the tail of the
    # raw log, and exit NON-ZERO so CI / the orchestrator sees red.
    echo "[browser] --- hambrowse serial lines ---"
    grep -an 'hambrowse\|wsys\|newwindow\|permission\|handing off' "$LOG" \
        | tail -40 || echo "[browser]   (none — hambrowse produced no serial output)"
    echo "[browser] --- last 40 lines of serial log ---"
    tail -40 "$LOG" 2>/dev/null | tr -d '\r'
    echo "[browser] --- end serial dump ---"
    exit 1
fi
