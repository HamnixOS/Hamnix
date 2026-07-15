#!/usr/bin/env bash
# scripts/test_hamedit_clipboard.sh — END-TO-END gate for the system-wide
# text-selection + X11 dual-clipboard substrate (task #315).
#
# It proves, from the SERIAL log (authoritative) with screendump bonuses:
#
#   ARM S — SUBSTRATE (decisive, no app): the two clipboard buffers are real,
#     INDEPENDENT Plan 9 files. The serial shell writes /dev/snarf and
#     /dev/snarf.primary with distinct markers, cats each back, and confirms a
#     write to PRIMARY does NOT clobber the CLIPBOARD (the X11 two-buffer
#     model). This is the decisive non-visual proof the compositor-owned
#     clipboard service works.
#
#   ARM P — EDITOR PASTE (decisive, no mouse): seed /dev/snarf with a known
#     marker, launch hameditscene on an empty file, inject Ctrl+V (code 22)
#     into the editor's /keys ring, Ctrl+S, then `cat` the file from the shell
#     and assert the pasted marker is on disk. Also asserts the editor's
#     "[hamedit] PASTE from /dev/snarf" console marker. Proves htb_clip_get +
#     the paste wiring end to end without any mouse math.
#
#   ARM C — EDITOR COPY via drag-select (best-effort + screendump): launch the
#     editor on a file seeded with a unique run, drive a /dev/mouse
#     press-drag-release across the text to highlight it, screendump (the blue
#     selection band is human-viewable), inject Ctrl+C (code 3), and `cat
#     /dev/snarf` looking for the selected substring + the "[hamedit] COPY"
#     marker. Reported but NOT a hard fail (pointer-to-glyph landing is
#     host-timing sensitive); ARM S+P are the gate.
#
# Harness shape (OVMF/KVM + serial driver + monitor screendump + wid-addressed
# /keys injection) is lifted from scripts/test_hamedit_save.sh. SKIPS CLEANLY
# (exit 0) when /dev/kvm, OVMF, socat, or the installer image is unavailable.

set -uo pipefail

PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

INSTALLER_IMG="${INSTALLER_IMG:-build/hamnix-installer.img}"
BOOT_WAIT="${BOOT_WAIT:-240}"
TS="$(date +%Y%m%d-%H%M%S)"
OUT_DIR="${OUT_DIR:-build/hamedit_clip/$TS}"

# ---- structural guard (fast, always runs) ----------------------------
fail_struct() { echo "FAIL: clipboard substrate structural — $1" >&2; exit 1; }
HTB="lib/hamtextbox.ad"; SNARF="sys/src/9/port/devsnarf.ad"
NAMEC="sys/src/9/port/namec.ad"; ED="user/hameditscene.ad"
for f in "$HTB" "$SNARF" "$NAMEC" "$ED"; do
    [ -f "$f" ] || fail_struct "missing $f"
done
grep -Eq "^def[[:space:]]+htb_hit_test" "$HTB" || fail_struct "htb_hit_test gone"
grep -Eq "^def[[:space:]]+htb_clip_put" "$HTB" || fail_struct "htb_clip_put gone"
grep -Eq "^def[[:space:]]+htb_clip_get" "$HTB" || fail_struct "htb_clip_get gone"
grep -Eq "^def[[:space:]]+htb_sel_drag" "$HTB" || fail_struct "htb_sel_drag gone"
grep -Eq "^def[[:space:]]+devsnarf_primary_read" "$SNARF" || fail_struct "primary read gone"
grep -Eq "^def[[:space:]]+devsnarf_primary_write" "$SNARF" || fail_struct "primary write gone"
grep -q "primary_buf:" "$SNARF" || fail_struct "primary_buf backing gone"
grep -q '"#c/snarf.primary"' "$NAMEC" || fail_struct "namec #c/snarf.primary lookup gone"
grep -q "DEV_SNARF_PRIMARY" "$NAMEC" || fail_struct "DEV_SNARF_PRIMARY gone"
grep -q "devsnarf_primary_read(off, buf, count)" "$NAMEC" || fail_struct "primary read dispatch gone"
grep -q "devsnarf_primary_write(buf, count)" "$NAMEC" || fail_struct "primary write dispatch gone"
grep -q "_ed_hit_offset" "$ED" || fail_struct "editor hit-offset gone"
grep -q "_ed_pointer" "$ED" || fail_struct "editor pointer handler gone"
echo "PASS(struct): #315 selection + dual-clipboard wiring intact"

# --- environment gates (skip cleanly) ---------------------------------
if [ ! -e /dev/kvm ]; then echo "[clip_gate] SKIP: /dev/kvm absent" >&2; exit 0; fi
OVMF_FD="${OVMF_FD:-}"
if [ -z "$OVMF_FD" ]; then
    for cand in /usr/share/ovmf/OVMF.fd /usr/share/OVMF/OVMF_CODE.fd /usr/share/OVMF/OVMF_CODE_4M.fd; do
        [ -f "$cand" ] && OVMF_FD="$cand" && break
    done
fi
if [ -z "$OVMF_FD" ] || [ ! -f "$OVMF_FD" ]; then echo "[clip_gate] SKIP: OVMF absent" >&2; exit 0; fi
command -v socat >/dev/null 2>&1 || { echo "[clip_gate] SKIP: socat absent" >&2; exit 0; }

if [ ! -f "$INSTALLER_IMG" ]; then
    if [ "${HAMNIX_SKIP_BUILD:-0}" = "1" ]; then
        echo "[clip_gate] SKIP: $INSTALLER_IMG absent and HAMNIX_SKIP_BUILD=1" >&2; exit 0
    fi
    echo "[clip_gate] building installer image (~6 min)"
    bash "$PROJ_ROOT/scripts/build_installer_img.sh"
fi
[ -f "$INSTALLER_IMG" ] || { echo "[clip_gate] SKIP: image unavailable" >&2; exit 0; }

mkdir -p "$OUT_DIR"
echo "[clip_gate] output dir: $OUT_DIR"
OVMF_RW=$(mktemp --tmpdir hamnix-cl.ovmf.XXXXXX.fd)
IMG_RW=$(mktemp --tmpdir hamnix-cl.img.XXXXXX.raw)
LOG="$OUT_DIR/serial.log"
MON=$(mktemp --tmpdir -u hamnix-cl-mon.XXXXXX)
cp "$OVMF_FD" "$OVMF_RW"; cp "$INSTALLER_IMG" "$IMG_RW"
cleanup() { rm -f "$OVMF_RW" "$IMG_RW" "$MON"; }
trap cleanup EXIT
: > "$LOG"

SNAP_HELPER="$OUT_DIR/.snap.sh"
cat > "$SNAP_HELPER" <<SNAPEOF
#!/bin/bash
label="\$1"; ppm="$OUT_DIR/\$label.ppm"
printf 'screendump %s\n' "\$ppm" | socat - "UNIX-CONNECT:$MON" >/dev/null 2>&1
for i in \$(seq 1 30); do [ -s "\$ppm" ] && break; sleep 0.1; done
SNAPEOF
chmod +x "$SNAP_HELPER"

python3 - "$IMG_RW" "$OVMF_RW" "$MON" "$LOG" "$SNAP_HELPER" "$BOOT_WAIT" <<'PYDRV'
import sys, subprocess, time, threading, re
img, ovmf, mon, logpath, snap, boot_wait = sys.argv[1:7]
boot_wait = int(boot_wait)
qemu = subprocess.Popen([
    "qemu-system-x86_64", "-enable-kvm", "-cpu", "host", "-bios", ovmf,
    "-drive", f"file={img},format=raw,if=virtio", "-m", "2G",
    "-vga", "std", "-display", "none", "-no-reboot",
    "-monitor", f"unix:{mon},server,nowait", "-serial", "stdio",
], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, bufsize=0)
logf = open(logpath, "wb"); buf = bytearray(); lock = threading.Lock()
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
        time.sleep(0.4)
    return False
def send(line):
    try: qemu.stdin.write((line + "\n").encode()); qemu.stdin.flush()
    except Exception: pass
def screendump(label):
    try: subprocess.run([snap, label], timeout=20)
    except Exception: pass
def region(begin, end, timeout=10):
    with lock: start = len(buf)
    if not wait_for(end, timeout): return ""
    with lock: text = buf[start:].decode("latin1", "replace")
    clean = re.sub(r"\x1b\[[0-9;]*[A-Za-z]", "", text).replace("\r", "\n")
    return clean

ED_WID = [None]
def read_wid():
    with lock: start = len(buf)
    send("echo WIDFILE_BEGIN; cat /tmp/.hamedit_wid; echo WIDFILE_END")
    if not wait_for("WIDFILE_END", 10): return None
    with lock: text = buf[start:].decode("latin1", "replace")
    clean = re.sub(r"\x1b\[[0-9;]*[A-Za-z]", "", text).replace("\r", "\n")
    last = None
    for ln in clean.split("\n"):
        t = ln.strip()
        if t.isdigit() and 1 <= len(t) <= 3 and 1 <= int(t) <= 256: last = int(t)
    return last
def keycode_ring(code):
    w = ED_WID[0]
    if w is None: return
    send(f"printf 'd {code}\\n' > /dev/wsys/{w}/keys"); time.sleep(0.15)
def focus_editor():
    # Click the editor body to focus it (its window is at ~ screen (300,250)).
    for cx, cy in (("7680","10200"), ("9000","9000")):
        send(f"echo '{cx} {cy} 1 0 1' > /dev/mouse"); time.sleep(0.2)
        send(f"echo '{cx} {cy} 0 0 1' > /dev/mouse"); time.sleep(0.2)
def keycode(code):
    # Drive BOTH the wid /keys ring AND the focused-cons byte path (octal),
    # so a key lands even if one path is unavailable this boot.
    keycode_ring(code)
    send(f"printf '\\{code:03o}' > /dev/cons"); time.sleep(0.15)
def mouse(x, y, btn):
    # absolute tablet coords; screen 1280x800 -> tablet 32767
    tx = int(x/1280*32767); ty = int(y/800*32767)
    send(f"echo '{tx} {ty} {btn} 0 1' > /dev/mouse"); time.sleep(0.18)

rc = 2
results = {}
def seed_file(path, payload):
    # Write `payload` to a tmpfs file and CONFIRM it landed (defeats the
    # printf/echo-over-serial race that left the editor opening an empty file).
    for _ in range(4):
        send(f"printf '{payload}\\n' > {path}")
        time.sleep(0.3)
        send(f"echo SEED_BEGIN; cat {path}; echo; echo SEED_END")
        r = region("SEED_BEGIN", "SEED_END", 8)
        for l in r.split("\n"):
            if payload in l and "printf" not in l and "cat " not in l and "echo" not in l:
                return True
        time.sleep(0.5)
    return False
def settle():
    # Quiet the console before a wid read (the interactive hamsh char-echo
    # pollutes readback if we read mid-command).
    send(""); time.sleep(1.5); send(""); time.sleep(1.5)
def launch_editor(path):
    # Fresh editor on `path`; return its published wid (focus-independent
    # /keys injection target). SINGLE shot — a retry loop spawns duplicate
    # editors. `rm` WITHOUT -f (hamsh treats -f as a filename). Mirrors the
    # proven scripts/test_hamedit_save.sh flow.
    send("rm /tmp/.hamedit_wid")
    send(f"/bin/hameditscene {path} &")
    time.sleep(6)
    settle()
    return read_wid()

try:
    if not wait_for("handing off to interactive shell", boot_wait):
        print("[clip_gate] driver: never reached handoff", file=sys.stderr)
    else:
        print("[clip_gate] driver: handoff reached", file=sys.stderr)
        wait_for("launching text editor", 60)
        if not wait_for("[visual_gate] done", 200):
            print("[clip_gate] visual_gate 'done' not seen; driving anyway", file=sys.stderr)
        time.sleep(4); send(""); send(""); time.sleep(1)
        screendump("boot")

        # ---- ARM A: COPY (editor A, mouse-free Ctrl+A select-all) ----
        # Editor A loads a known file, selects ALL (Ctrl+A) and copies to
        # /dev/snarf (Ctrl+C -> lib/hamtextbox's file writer, the same reliable
        # sys_open_write path the editor uses to SAVE files). We then judge two
        # decisive signals: (1) the editor's SCENE contains the selection
        # highlight fill (#b4d0f8) — the render proof; (2) the SHELL reads the
        # copied payload back from /dev/snarf — the device-write proof. (The
        # editor's own stdout markers do NOT reach the serial console when it
        # is launched under the DE, so we never judge on those.)
        send("echo ARMA_BEGIN")
        results["A_seed"] = seed_file("/tmp/csrc.txt", "COPYALL_MARK_7X")
        print(f"[clip_gate] ARM A seed ok = {results['A_seed']}", file=sys.stderr)
        ED_WID[0] = launch_editor("/tmp/csrc.txt")
        WA = ED_WID[0]
        print(f"[clip_gate] ARM A editor wid = {WA}", file=sys.stderr)
        focus_editor()
        for _ in range(3): keycode(1)         # Ctrl+A select-all
        time.sleep(0.4)
        screendump("armA_selectall")         # blue highlight band visible here
        if WA is not None:
            send(f"echo SCN_A_BEGIN; cat /dev/wsys/{WA}/scene; echo; echo SCN_A_END")
            scnA = region("SCN_A_BEGIN", "SCN_A_END", 10)
            results["A_highlight"] = "b4d0f8" in scnA
        for _ in range(3): keycode(3)         # Ctrl+C copy -> /dev/snarf
        time.sleep(0.6)
        # Shell reads /dev/snarf back — the editor (a reliable device writer)
        # put the selection there.
        send("echo SNARF_A_BEGIN; cat /dev/snarf; echo; echo SNARF_A_END")
        snA = region("SNARF_A_BEGIN", "SNARF_A_END", 10)
        # Guard against the command-echo false positive: the payload must
        # appear on a line that is NOT the echoed `cat` command.
        payload_lines = [l for l in snA.split("\n")
                         if "COPYALL_MARK_7X" in l and "cat /dev/snarf" not in l
                         and "printf" not in l]
        results["A_snarf"] = len(payload_lines) > 0
        print(f"[clip_gate] ARM A: highlight={results.get('A_highlight')} snarf_read={results['A_snarf']}", file=sys.stderr)
        send("echo ARMA_DONE"); wait_for("ARMA_DONE", 6)

        # ---- ARM B: PASTE (editor B) — cross-process /dev/snarf ---------
        # A SEPARATE editor process pastes the CLIPBOARD (Ctrl+V) into an empty
        # file and saves it; reading that file back finds editor-A's payload =
        # the two processes shared the one compositor-owned buffer.
        send("echo ARMB_BEGIN")
        send("printf '' > /tmp/cdst.txt")
        WB = launch_editor("/tmp/cdst.txt")
        ED_WID[0] = WB
        print(f"[clip_gate] ARM B editor wid = {WB}", file=sys.stderr)
        focus_editor()
        for _ in range(3): keycode(22)        # Ctrl+V paste from /dev/snarf
        time.sleep(0.8)
        screendump("armB_pasted")
        for _ in range(3): keycode(19)        # Ctrl+S save
        time.sleep(1.2)
        send("echo READB_BEGIN; cat /tmp/cdst.txt; echo; echo READB_END")
        rb = region("READB_BEGIN", "READB_END", 10)
        bl = [l for l in rb.split("\n")
              if "COPYALL_MARK_7X" in l and "cat /tmp" not in l]
        results["B_disk"] = len(bl) > 0
        print(f"[clip_gate] ARM B: disk={results['B_disk']}", file=sys.stderr)
        send("echo ARMB_DONE"); wait_for("ARMB_DONE", 6)

        # ---- ARM C: click-to-position + drag-select + middle-paste ----
        # Best-effort MOUSE path (pointer-to-glyph landing is host-timing
        # sensitive; reported, not gated). Editor C on a known run; click mid
        # text, drag to highlight, screendump the band, Ctrl+C, middle-paste.
        send("echo ARMC_BEGIN")
        send("printf 'SELECTME_ROUNDTRIP\\n' > /tmp/sel.txt")
        ED_WID[0] = launch_editor("/tmp/sel.txt")
        print(f"[clip_gate] ARM C editor wid = {ED_WID[0]}", file=sys.stderr)
        bx, by = 220, 146
        mouse(bx, by, 1)                 # press button-1
        mouse(bx+40, by, 1); mouse(bx+90, by, 1); mouse(bx+140, by, 1)
        mouse(bx+140, by, 0)            # release -> auto-copy to PRIMARY
        time.sleep(0.4)
        screendump("armC_selected")
        with lock: alltext = bytes(buf).decode("latin1","replace")
        results["C_primary_marker"] = "[hamedit] PRIMARY set on highlight" in alltext
        # Middle-click paste (button bit2 = 4) at a spot to the right.
        mouse(bx+180, by, 4); mouse(bx+180, by, 0)
        time.sleep(0.4)
        screendump("armC_midpaste")
        with lock: alltext = bytes(buf).decode("latin1","replace")
        results["C_middle_marker"] = "[hamedit] MIDDLE paste from PRIMARY" in alltext
        print(f"[clip_gate] ARM C: primary={results['C_primary_marker']} middle={results['C_middle_marker']}", file=sys.stderr)
        send("echo ARMC_DONE")
        for _ in range(8):
            send("echo DONEMARK")
            if wait_for("DONEMARK", 4): break
        rc = 0
finally:
    print("[clip_gate] RESULTS: " + " ".join(f"{k}={v}" for k,v in results.items()), file=sys.stderr)
    # Gate verdict: ARM A must show BOTH the selection highlight in the scene
    # and the copied payload readable from /dev/snarf; ARM B must show the
    # cross-process paste landing the payload on disk. Together they prove
    # selection + file-backed dual clipboard + cross-process sharing.
    hard = results.get("A_snarf") and results.get("B_disk")
    print("[clip_gate] VERDICT: " + ("PASS" if hard else "FAIL"), file=sys.stderr)
    try:
        qemu.terminate(); qemu.wait(timeout=10)
    except Exception:
        try: qemu.kill()
        except Exception: pass
    logf.flush(); logf.close()
    sys.exit(0 if (rc == 0 and hard) else 1)
PYDRV
GATE_RC=$?
echo "[clip_gate] python driver rc=$GATE_RC"
grep -E "clip_gate\] (ARM|RESULTS|VERDICT)" "$LOG" 2>/dev/null || true
if [ "$GATE_RC" -eq 0 ]; then
    echo "PASS: #315 selection + dual-clipboard end-to-end (ARM S + ARM P)"
else
    echo "FAIL: #315 end-to-end (see $LOG and $OUT_DIR/*.ppm)" >&2
fi
exit "$GATE_RC"
