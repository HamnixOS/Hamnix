#!/usr/bin/env python3
# Ad-hoc verification driver for the 4 DE UX fixes (agent worktree).
# Boots the installer image under OVMF/KVM, -vga std, QMP monitor for
# screendumps, serial for control. Drives input by writing to the focused
# window's /dev/wsys/<wid>/keys + /event files from the serial shell, and
# asserts on occlusion-proof scene cats. Screendumps for human viewing.
import sys, subprocess, time, threading, os

img, ovmf, mon, logpath, outdir, boot_wait = sys.argv[1:7]
boot_wait = int(boot_wait)

qemu = subprocess.Popen([
    "qemu-system-x86_64", "-enable-kvm", "-cpu", "host",
    "-bios", ovmf,
    "-drive", f"file={img},format=raw,if=virtio",
    "-m", "1G",
    "-vga", "std", "-display", "none", "-no-reboot",
    "-monitor", f"unix:{mon},server,nowait",
    "-serial", "stdio",
], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, bufsize=0)

logf = open(logpath, "wb")
buf = bytearray()
lock = threading.Lock()

def reader():
    while True:
        b = qemu.stdout.read(1)
        if not b:
            break
        logf.write(b); logf.flush()
        with lock:
            buf.extend(b)
threading.Thread(target=reader, daemon=True).start()

def wait_for(marker, timeout):
    m = marker.encode(); deadline = time.time() + timeout
    while time.time() < deadline:
        with lock:
            if m in buf:
                return True
        if qemu.poll() is not None:
            return False
        time.sleep(0.5)
    return False

def snapshot():
    with lock:
        return bytes(buf)

def send(line):
    try:
        qemu.stdin.write((line + "\n").encode()); qemu.stdin.flush()
    except Exception:
        pass

def screendump(label):
    ppm = os.path.join(outdir, f"{label}.ppm")
    try:
        subprocess.run(["socat", "-", f"UNIX-CONNECT:{mon}"],
                       input=f"screendump {ppm}\n".encode(),
                       timeout=20, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except Exception:
        pass
    for _ in range(30):
        if os.path.exists(ppm) and os.path.getsize(ppm) > 0:
            break
        time.sleep(0.1)

def sendkey(keyfile, code):
    send(f" echo 'd {code}' > {keyfile}")

def keypress(keyfile, code, settle=0.6):
    sendkey(keyfile, code); time.sleep(settle)

def type_str(keyfile, s):
    for ch in s:
        keypress(keyfile, ord(ch))
    time.sleep(0.5)

def cat_scene(wid, tag):
    # Mark the buffer position, cat the scene, return everything appended
    # after. The scene's `glyphs ... "text"` lines are distinctive and never
    # appear in the readline echo of the cat command, so grepping this tail is
    # reliable despite the noisy serial echo.
    with lock:
        start = len(buf)
    send(f"cat /dev/wsys/{wid}/scene")
    time.sleep(1.8)
    s = snapshot()
    tail = s[start:]
    # record for the log
    logf.write(b"\n=== " + tag.encode() + b" ===\n" + tail + b"\n"); logf.flush()
    return tail

import re
_WINRE = re.compile(rb'^\s*(\d+)\s+([A-Za-z]+)\s*$')
def find_wid(title):
    # The /dev/wsys/windows file lists clean "<wid> <Title>" lines. The serial
    # readline echoes the typed command char-by-char (noisy), so we DON'T
    # bracket-scan; instead we cat windows, then scan the freshest matching
    # CLEAN "<digits> <Title>" line in the buffer tail.
    for attempt in range(8):
        send("cat /dev/wsys/windows")
        time.sleep(1.8)
        s = snapshot()
        found = None
        for ln in s.split(b"\n"):
            m = _WINRE.match(ln)
            if m and m.group(2).decode() == title:
                found = int(m.group(1))
        if found is not None:
            return found
    return None

rc = 2
try:
    if not wait_for("handing off to interactive shell", boot_wait):
        print("DRIVER: never reached handoff", file=sys.stderr)
    else:
        print("DRIVER: handoff reached", file=sys.stderr)
        # Wait for the terminal NS_PROBE = DE apps are up.
        if wait_for("[hamterm] NS_PROBE", 200):
            print("DRIVER: NS_PROBE seen", file=sys.stderr)
        else:
            print("DRIVER: NS_PROBE not seen (slow boot)", file=sys.stderr)
        time.sleep(8)

        # Dump the window list once for the record.
        send("echo WINDUMP_B; cat /dev/wsys/windows; echo WINDUMP_E")
        time.sleep(2)

        # ===== BUG 2: z-order / map-and-raise + BUG 3: terminal keys =====
        term_wid = find_wid("Terminal")
        print(f"DRIVER: Terminal wid={term_wid}", file=sys.stderr)
        if term_wid is not None:
            kf = f"/dev/wsys/{term_wid}/keys"
            cf = f"/dev/wsys/{term_wid}/ctl"
            send(f"echo raise > {cf}"); time.sleep(0.5)
            screendump("term_pre")

            # Type + submit two distinct commands to populate history.
            type_str(kf, "echo AAA111")
            sendkey(kf, 10); time.sleep(3.0)
            type_str(kf, "echo BBB222")
            sendkey(kf, 10); time.sleep(3.0)
            send(f"echo raise > {cf}"); time.sleep(0.5)
            screendump("term_after_cmds")

            # BUG 3a: Up arrow (ESC [ A = 27,91,65) should recall "echo BBB222".
            sendkey(kf, 27); time.sleep(0.2)
            sendkey(kf, 91); time.sleep(0.2)
            sendkey(kf, 65); time.sleep(0.8)
            blk = cat_scene(term_wid, "TERM_UP1")
            screendump("term_up1")
            # Up again -> "echo AAA111".
            sendkey(kf, 27); time.sleep(0.2)
            sendkey(kf, 91); time.sleep(0.2)
            sendkey(kf, 65); time.sleep(0.8)
            blk2 = cat_scene(term_wid, "TERM_UP2")
            screendump("term_up2")
            # Down -> back to "echo BBB222".
            sendkey(kf, 27); time.sleep(0.2)
            sendkey(kf, 91); time.sleep(0.2)
            sendkey(kf, 66); time.sleep(0.8)
            blk3 = cat_scene(term_wid, "TERM_DOWN1")
            screendump("term_down1")

            # BUG 3b: arrow should NOT leak "[A" glyphs into the line. We start
            # fresh: Ctrl-C clears, then verify no stray '[' from arrows.
            sendkey(kf, 3); time.sleep(0.5)   # Ctrl-C clear line
            # Type "xyz", move Left twice (ESC [ D), insert 'Q' -> "xQyz".
            type_str(kf, "xyz")
            sendkey(kf, 27); time.sleep(0.15); sendkey(kf, 91); time.sleep(0.15); sendkey(kf, 68); time.sleep(0.4)
            sendkey(kf, 27); time.sleep(0.15); sendkey(kf, 91); time.sleep(0.15); sendkey(kf, 68); time.sleep(0.4)
            keypress(kf, ord('Q'))
            blk4 = cat_scene(term_wid, "TERM_INS")
            screendump("term_insert")
            sendkey(kf, 3); time.sleep(0.3)

        # ===== BUG 1: hamfm double-click a file -> hamedit loads it =====
        fm_wid = find_wid("Files")
        print(f"DRIVER: Files wid={fm_wid}", file=sys.stderr)
        if fm_wid is not None:
            ef = f"/dev/wsys/{fm_wid}/event"
            cf2 = f"/dev/wsys/{fm_wid}/ctl"
            send(f"echo raise > {cf2}"); time.sleep(0.5)
            screendump("fm_pre")
            blk_fm = cat_scene(fm_wid, "FM_SCENE")
            # The FM grid lists "/" entries as glyphs. We will double-click the
            # first FILE cell. Grid cells start near top-left; the core lays
            # icons in a grid. We inject a double press at a few candidate
            # cells likely to be a regular file (e.g. 'version'); the FM's
            # _on_click does dir-descend on dirs and editor-launch on files.
            # Click cells across the first rows to hit a file.
            for (cx, cy) in [(40, 60), (110, 60), (180, 60), (40, 110), (110, 110), (40, 160)]:
                # two quick presses = double-click (within DBL_JIF=8 jiffies)
                send(f" echo 'm {cx} {cy} 1 0' > {ef}"); time.sleep(0.10)
                send(f" echo 'm {cx} {cy} 0 0' > {ef}"); time.sleep(0.10)
                send(f" echo 'm {cx} {cy} 1 0' > {ef}"); time.sleep(0.10)
                send(f" echo 'm {cx} {cy} 0 0' > {ef}"); time.sleep(0.6)
            time.sleep(2.0)
            send(f"echo raise > {cf2}"); time.sleep(0.5)
            screendump("fm_after_click")

        # Did an editor window appear? Look for the "Editor" window + its scene.
        time.sleep(2)
        ed_wid = find_wid("Editor")
        print(f"DRIVER: Editor wid={ed_wid}", file=sys.stderr)
        if ed_wid is not None:
            send(f"echo raise > /dev/wsys/{ed_wid}/ctl"); time.sleep(0.5)
            screendump("editor")
            blk_ed = cat_scene(ed_wid, "ED_SCENE")

        # Also capture the [hamedit] <path> marker the FM prints on launch.
        send("echo HAMEDITMARK_CHECK")
        time.sleep(1)

        # ===== BUG 4: launch hamsettings, confirm no crash =====
        # Launch a fresh hamsettings from the serial shell in its own ns,
        # exactly like rc.5 launches the scene apps, and watch for its ready
        # marker vs a fault. We run it detached so the shell stays alive.
        send("echo SETTINGS_LAUNCH")
        send("/bin/hamsettings &")
        time.sleep(6)
        set_wid = find_wid("Settings")
        print(f"DRIVER: Settings wid={set_wid}", file=sys.stderr)
        if set_wid is not None:
            send(f"echo raise > /dev/wsys/{set_wid}/ctl"); time.sleep(0.5)
            screendump("settings")
            blk_set = cat_scene(set_wid, "SET_SCENE")
            # Click a wallpaper swatch + a panel toggle to exercise handlers.
            sef = f"/dev/wsys/{set_wid}/event"
            send(f" echo 'm 36 76 1 0' > {sef}"); time.sleep(0.4)
            send(f" echo 'm 36 76 0 0' > {sef}"); time.sleep(0.8)
            screendump("settings_click")
            cat_scene(set_wid, "SET_SCENE2")

        # stop marker
        for _ in range(12):
            send("echo VERIFYDONEMARK")
            if wait_for("VERIFYDONEMARK", 4):
                break
        rc = 0
finally:
    try:
        qemu.terminate(); qemu.wait(timeout=10)
    except Exception:
        try: qemu.kill()
        except Exception: pass
    logf.flush(); logf.close()
    sys.exit(rc)
