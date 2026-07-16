#!/usr/bin/env bash
# scripts/verify_calc_expr_ondevice.sh — ON-DEVICE proof for the #329 running-
# expression LCD (USER re-report). Boots the SHIPPED installer image under
# OVMF/KVM, focuses the DE calculator, injects `5 + 5 =` via the QEMU monitor
# sendkey path (REAL scancodes -> atkbd -> compositor -> calc /keys, exactly
# what a human at the keyboard does), and screendumps the framebuffer after
# each key. The LCD must read: 5 -> 5+ -> 5+5 -> 10.
set -u
cd "$(dirname "$0")/.." || exit 1

TS="$(date +%Y%m%d-%H%M%S)"
OUT_DIR="${OUT_DIR:-build/calc_expr_ondevice/$TS}"
mkdir -p "$OUT_DIR"
INSTALLER_IMG="${INSTALLER_IMG:-build/hamnix-installer.img}"
BOOT_WAIT="${BOOT_WAIT:-300}"
OVMF_FD="${OVMF_FD:-/usr/share/OVMF/OVMF_CODE.fd}"
[ -f "$OVMF_FD" ] || OVMF_FD="/usr/share/ovmf/OVMF.fd"

[ -e /dev/kvm ] || { echo "SKIP: /dev/kvm absent" >&2; exit 0; }
[ -f "$OVMF_FD" ] || { echo "SKIP: OVMF firmware not found" >&2; exit 0; }
command -v socat >/dev/null 2>&1 || { echo "SKIP: socat required" >&2; exit 0; }
[ -f "$INSTALLER_IMG" ] || { echo "SKIP: $INSTALLER_IMG absent" >&2; exit 0; }

echo "[calc_expr] output dir: $OUT_DIR"
OVMF_RW=$(mktemp --tmpdir hamnix-ce.ovmf.XXXXXX.fd)
IMG_RW=$(mktemp --tmpdir hamnix-ce.img.XXXXXX.raw)
LOG="$OUT_DIR/serial.log"
MON=$(mktemp --tmpdir -u hamnix-ce-mon.XXXXXX)
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
for i in \$(seq 1 40); do [ -s "\$ppm" ] && break; sleep 0.1; done
SNAPEOF
chmod +x "$SNAP_HELPER"

KEY_HELPER="$OUT_DIR/.key.sh"
cat > "$KEY_HELPER" <<KEYEOF
#!/bin/bash
printf 'sendkey %s\n' "\$1" | socat - "UNIX-CONNECT:$MON" >/dev/null 2>&1
KEYEOF
chmod +x "$KEY_HELPER"

python3 - "$IMG_RW" "$OVMF_RW" "$MON" "$LOG" "$SNAP_HELPER" "$KEY_HELPER" "$BOOT_WAIT" <<'PYDRV'
import sys, subprocess, time, threading
img, ovmf, mon, logpath, snap, keyh, boot_wait = sys.argv[1:8]
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
    subprocess.run([snap, label], timeout=25)
    print(f"[calc_expr] driver: screendump {label}", file=sys.stderr)
def key(k):
    subprocess.run([keyh, k], timeout=15)
    time.sleep(0.7)
try:
    if not wait_for("handing off to interactive shell", boot_wait):
        print("[calc_expr] driver: never reached handoff", file=sys.stderr)
    else:
        print("[calc_expr] driver: handoff reached", file=sys.stderr)
        wait_for("[scene_de] launching calculator", 90)
        time.sleep(12)
        screendump("s0_desktop")
        # Relaunch the calculator through the REAL DE launch queue so it is the
        # newest -> topmost -> focused window (the editor autostarts after it).
        send("echo /bin/hamcalcscene > /dev/wsys/run/launch")
        time.sleep(8)
        screendump("s1_calc_focused")
        # Type 5 + 5 = with a screendump after each key.
        key("5");           screendump("s2_5")
        key("shift-equal"); screendump("s3_plus")
        key("5");           screendump("s4_55")
        key("equal");       screendump("s5_eq")
        # Second attempt via Alt-Tab focus (in case relaunch didn't focus):
        key("c")                     # clear
        key("alt-tab"); time.sleep(1)
        screendump("s6_alttab")
        key("5");           screendump("s7_5")
        key("shift-equal"); screendump("s8_plus")
        key("5");           screendump("s9_55")
        key("equal");       screendump("s10_eq")
        print("[calc_expr] driver: done", file=sys.stderr)
finally:
    try: qemu.stdin.close()
    except Exception: pass
    try: qemu.terminate()
    except Exception: pass
    try: qemu.wait(timeout=10)
    except Exception:
        qemu.kill()
PYDRV

echo "[calc_expr] --- converting screendumps ---"
for ppm in "$OUT_DIR"/*.ppm; do
    [ -s "$ppm" ] || continue
    png="${ppm%.ppm}.png"
    if command -v pnmtopng >/dev/null 2>&1; then
        pnmtopng "$ppm" > "$png" 2>/dev/null || true
    elif [ -f scripts/ppm_to_png.py ]; then
        python3 scripts/ppm_to_png.py "$ppm" "$png" 2>/dev/null || true
    fi
    [ -s "$png" ] && echo "[calc_expr] $png"
done
grep -aq 'kernel panic\|triple fault' "$LOG" && echo "[calc_expr] WARN panic in log" || echo "[calc_expr] no panic"
echo "[calc_expr] artifacts in $OUT_DIR"
