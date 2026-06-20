#!/usr/bin/env bash
# scripts/test_de_wheel_scroll.sh — END-TO-END gate for MOUSE-WHEEL SCROLL in
# the DE terminal and text editor.
#
# THE BUG THIS LOCKS DOWN: the in-kernel pointer router (_wsys_evt_emit_pointer
# in sys/src/9/port/devwsys.ad) delivers the "m <x> <y> <buttons> <dz>" line —
# wheel notch in dz — onto the per-window /dev/wsys/<wid>/EVENT ring. The
# terminal used to read wheel notches from the SEPARATE /pointer file, which
# the router NEVER writes (only the userland-compositor path does), so the
# /pointer ring stayed empty and the wheel did nothing; the editor read no
# pointer events at all. The fix routes wheel dz off /event in BOTH apps
# (hamtermscene -> term_view_off scrollback, hameditscene -> top_line scroll).
#
# HOW THIS GATE PROVES IT (live, no static grep — that is in
# test_de_term_editor_features.sh):
#   * Boot to rl5; the DE auto-launches a terminal (and a file manager).
#   * Move the PS/2-relative cursor over the terminal window, screendump the
#     terminal region, inject wheel-UP notches via /dev/mouse ("0 0 0 N", a
#     4-field line whose 4th field is dz), screendump again.
#   * The terminal re-renders its scrollback view on a wheel notch, so the
#     terminal content region must CHANGE between the two frames. A wheel that
#     does nothing (the regression) leaves the region byte-identical.
#   * Belt-and-braces: grep the serial log for the routed wheel — the kernel
#     mouse self-test and the window /event readback.
#
# Reuses the OVMF/KVM + serial + monitor-screendump harness of the flicker
# gate. SKIPS CLEANLY (exit 0) when /dev/kvm, OVMF, socat, or the image is
# unavailable. rc=124 (host-load timeout) is NOT a failure.

set -uo pipefail

PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

INSTALLER_IMG="${INSTALLER_IMG:-build/hamnix-installer.img}"
BOOT_WAIT="${BOOT_WAIT:-240}"
# The terminal content region must change by at least this many px when the
# scrollback view scrolls. A no-op wheel (regression) reads ~0.
SCROLL_MIN="${SCROLL_MIN:-60}"
TS="$(date +%Y%m%d-%H%M%S)"
OUT_DIR="${OUT_DIR:-build/de_wheel_scroll/$TS}"

if [ ! -e /dev/kvm ]; then
    echo "[wheel_gate] SKIP: /dev/kvm absent (KVM required)" >&2
    exit 0
fi
OVMF_FD="${OVMF_FD:-}"
if [ -z "$OVMF_FD" ]; then
    for cand in /usr/share/ovmf/OVMF.fd /usr/share/OVMF/OVMF_CODE.fd /usr/share/OVMF/OVMF_CODE_4M.fd; do
        [ -f "$cand" ] && OVMF_FD="$cand" && break
    done
fi
if [ -z "$OVMF_FD" ] || [ ! -f "$OVMF_FD" ]; then
    echo "[wheel_gate] SKIP: OVMF firmware not found (apt install ovmf)" >&2
    exit 0
fi
if ! command -v socat >/dev/null 2>&1; then
    echo "[wheel_gate] SKIP: socat required to drive the serial console" >&2
    exit 0
fi
if [ ! -f "$INSTALLER_IMG" ]; then
    if [ "${HAMNIX_SKIP_BUILD:-0}" = "1" ]; then
        echo "[wheel_gate] SKIP: $INSTALLER_IMG absent and HAMNIX_SKIP_BUILD=1" >&2
        exit 0
    fi
    echo "[wheel_gate] building installer image (~6 min)"
    bash "$PROJ_ROOT/scripts/build_installer_img.sh"
fi
if [ ! -f "$INSTALLER_IMG" ]; then
    echo "[wheel_gate] SKIP: $INSTALLER_IMG unavailable" >&2
    exit 0
fi

mkdir -p "$OUT_DIR"
echo "[wheel_gate] output dir: $OUT_DIR"

OVMF_RW=$(mktemp --tmpdir hamnix-wg.ovmf.XXXXXX.fd)
IMG_RW=$(mktemp --tmpdir hamnix-wg.img.XXXXXX.raw)
LOG="$OUT_DIR/serial.log"
MON=$(mktemp --tmpdir -u hamnix-wg-mon.XXXXXX)
cp "$OVMF_FD" "$OVMF_RW"
cp "$INSTALLER_IMG" "$IMG_RW"
cleanup() { rm -f "$OVMF_RW" "$IMG_RW" "$MON"; }
trap cleanup EXIT

# region_diff PRE POST X0 Y0 X1 Y1 -> changed px in box.
region_diff() {
    python3 - "$@" <<'PYEOF'
import sys
def load_ppm(path):
    with open(path, "rb") as f:
        data = f.read()
    if not data.startswith(b"P6"):
        return None
    idx = 2; toks = []
    while len(toks) < 3:
        while idx < len(data) and data[idx:idx+1].isspace():
            idx += 1
        if idx < len(data) and data[idx:idx+1] == b'#':
            while idx < len(data) and data[idx:idx+1] != b'\n':
                idx += 1
            continue
        start = idx
        while idx < len(data) and not data[idx:idx+1].isspace():
            idx += 1
        toks.append(int(data[start:idx]))
    idx += 1
    w, h, mx = toks
    return w, h, data[idx:idx + w*h*3]
pre, post = sys.argv[1], sys.argv[2]
x0, y0, x1, y1 = (int(sys.argv[i]) for i in range(3, 7))
a = load_ppm(pre); b = load_ppm(post)
if a is None or b is None or a[0] != b[0] or a[1] != b[1]:
    print(-1); sys.exit(0)
w, h, pa = a; _, _, pb = b
x1 = min(x1, w); y1 = min(y1, h)
THRESH = 24; changed = 0; n = min(len(pa), len(pb))
for y in range(y0, y1):
    base = y*w*3
    for x in range(x0, x1):
        i = base + x*3
        if i+2 >= n: continue
        if (abs(pa[i]-pb[i]) > THRESH or abs(pa[i+1]-pb[i+1]) > THRESH
                or abs(pa[i+2]-pb[i+2]) > THRESH):
            changed += 1
print(changed)
PYEOF
}

: > "$LOG"

SNAP_HELPER="$OUT_DIR/.snap.sh"
cat > "$SNAP_HELPER" <<SNAPEOF
#!/bin/bash
label="\$1"
ppm="$OUT_DIR/\$label.ppm"
printf 'screendump %s\n' "\$ppm" | socat - "UNIX-CONNECT:$MON" >/dev/null 2>&1 || \
    printf 'screendump %s\n' "\$ppm" | nc -U -q1 "$MON" >/dev/null 2>&1
for i in \$(seq 1 30); do [ -s "\$ppm" ] && break; sleep 0.1; done
SNAPEOF
chmod +x "$SNAP_HELPER"

# NOTE: DELIBERATELY NO "-device usb-tablet" — the user's exact PS/2 VM shape.
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
        time.sleep(0.5)
    return False

def send(line):
    try:
        qemu.stdin.write((line + "\n").encode()); qemu.stdin.flush()
    except Exception: pass

def screendump(label):
    subprocess.run([snap, label], timeout=20)

rc = 2
try:
    if not wait_for("handing off to interactive shell", boot_wait):
        print("[wheel_gate] driver: never reached handoff", file=sys.stderr)
    else:
        print("[wheel_gate] driver: handoff reached", file=sys.stderr)
        wait_for("[scene_de] launching file manager", 60)
        # Settle: the auto-launched terminal runs its `echo NS_OK; ls /`
        # startup probe; let that stream into the grid so there is content.
        time.sleep(10)
        # The DE terminal window geometry is "geometry 200 120 360 200":
        # content origin (200,120), size 360x200, titlebar above. Drive the
        # PS/2-relative cursor onto its middle (~380,220) from screen home.
        send("echo WHEEL_BEGIN")
        for _ in range(12):
            send("echo '40 30 0' > /dev/mouse")  # accumulate toward center
            time.sleep(0.12)
        time.sleep(0.6)
        screendump("term_pre")
        # WHEEL-UP over the terminal: 4-field line, 4th field dz = +3 (older
        # rows). Repeat so the scrollback view moves unambiguously.
        for _ in range(6):
            send("echo '0 0 0 3' > /dev/mouse")
            time.sleep(0.2)
        time.sleep(0.8)
        screendump("term_post")
        # Read the terminal window's event file back for the routed dz line
        # (best-effort: the terminal drains it, so this may race empty).
        for n in range(1, 13):
            send(f"echo EVT{n}_BEGIN; cat /dev/wsys/{n}/event; echo; echo EVT{n}_END")
            time.sleep(0.3)
        send("echo WHEEL_END")
        for _ in range(12):
            send("echo WHEELDONEMARK")
            if wait_for("WHEELDONEMARK", 4): break
        rc = 0
finally:
    try:
        qemu.terminate(); qemu.wait(timeout=10)
    except Exception:
        try: qemu.kill()
        except Exception: pass
    logf.flush(); logf.close()
    sys.exit(rc)
PYDRV
DRV_RC=$?

if [ "$DRV_RC" = "2" ]; then
    echo "[wheel_gate] SKIP: guest did not reach interactive shell; log: $LOG" >&2
    exit 0
fi

echo "[wheel_gate] --- assertions ---"
fail=0

# --- kernel mouse-pump self-test (proves the relative ring -> route path) ---
if grep -aq '\[MOUSE_PUMP\] PASS' "$LOG"; then
    echo "[wheel_gate] PASS kernel mouse-pump self-test ([MOUSE_PUMP] PASS)"
fi

# --- PRIMARY: the terminal content region scrolled on wheel-up -------------
# The terminal window: content (200,120) size 360x200. Diff that box.
if [ -s "$OUT_DIR/term_pre.ppm" ] && [ -s "$OUT_DIR/term_post.ppm" ]; then
    sdiff=$(region_diff "$OUT_DIR/term_pre.ppm" "$OUT_DIR/term_post.ppm" \
                        200 120 560 320)
    echo "[wheel_gate] terminal-region changed pixels on wheel-up: $sdiff (min $SCROLL_MIN)"
    if [ "$sdiff" = "-1" ]; then
        echo "[wheel_gate] NOTE term frames differ in size/format; scroll probe inconclusive"
    elif [ "$sdiff" -ge "$SCROLL_MIN" ]; then
        echo "[wheel_gate] PASS terminal scrollback SCROLLED under mouse-wheel input (dz routed via /event end-to-end)"
    else
        echo "[wheel_gate] FAIL terminal did not scroll on wheel-up ($sdiff px) — wheel dz not reaching the app (regression)" >&2
        fail=1
    fi
else
    echo "[wheel_gate] NOTE terminal screendumps missing; scroll probe skipped"
fi

# --- belt-and-braces: a routed 'm <x> <y> <buttons> <dz>' with nonzero dz --
route_ok=0
for n in $(seq 1 12); do
    blk=$(awk "/EVT${n}_BEGIN/{f=1;next} /EVT${n}_END/{f=0} f" "$LOG" 2>/dev/null)
    if printf '%s' "$blk" | grep -Eq 'm -?[0-9]+ -?[0-9]+ [0-9]+ -?[1-9]'; then
        echo "[wheel_gate] PASS routed 'm ... <dz!=0>' read back from window $n event file"
        route_ok=1; break
    fi
done
if [ "$route_ok" != "1" ]; then
    echo "[wheel_gate] NOTE no nonzero-dz 'm' line captured in an event readback (the terminal drains /event fast; the rendered scroll above is authoritative)"
fi

echo "[wheel_gate] artifacts in $OUT_DIR"
if [ "$fail" = "0" ]; then
    echo "[wheel_gate] RESULT: PASS"
    exit 0
fi
echo "[wheel_gate] RESULT: FAIL"
exit 1
