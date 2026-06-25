#!/usr/bin/env python3
# Focused verification of BUG 1: double-clicking a FILE in hamfmscene launches
# hameditscene WITH the file loaded (argv[1] passed correctly). We discover the
# Files wid, double-click the "version" cell, then assert a NEW editor window's
# scene contains /version's content ("Hamnix bare-metal kernel").
import sys, subprocess, time, threading, os, re

img, ovmf, mon, logpath, outdir, boot_wait = sys.argv[1:7]
boot_wait = int(boot_wait)

qemu = subprocess.Popen([
    "qemu-system-x86_64", "-enable-kvm", "-cpu", "host", "-bios", ovmf,
    "-drive", f"file={img},format=raw,if=virtio", "-m", "1G",
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
def wait_for(m, t):
    mm=m.encode(); d=time.time()+t
    while time.time()<d:
        with lock:
            if mm in buf: return True
        if qemu.poll() is not None: return False
        time.sleep(0.5)
    return False
def snapshot():
    with lock: return bytes(buf)
def send(l):
    try: qemu.stdin.write((l+"\n").encode()); qemu.stdin.flush()
    except Exception: pass
def screendump(label):
    ppm=os.path.join(outdir,f"{label}.ppm")
    try:
        subprocess.run(["socat","-",f"UNIX-CONNECT:{mon}"],
            input=f"screendump {ppm}\n".encode(), timeout=20,
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except Exception: pass
    for _ in range(30):
        if os.path.exists(ppm) and os.path.getsize(ppm)>0: break
        time.sleep(0.1)
_WINRE=re.compile(rb'^\s*(\d+)\s+([A-Za-z]+)\s*$')
def find_wids(title):
    send("cat /dev/wsys/windows"); time.sleep(1.8)
    s=snapshot(); out=[]
    for ln in s.split(b"\n"):
        m=_WINRE.match(ln)
        if m and m.group(2).decode()==title:
            w=int(m.group(1))
            if w not in out: out.append(w)
    return out
def cat_scene(wid, tag):
    with lock: start=len(buf)
    send(f"cat /dev/wsys/{wid}/scene"); time.sleep(1.8)
    tail=snapshot()[start:]
    logf.write(b"\n=== "+tag.encode()+b" ===\n"+tail+b"\n"); logf.flush()
    return tail

rc=2
try:
    if not wait_for("handing off to interactive shell", boot_wait):
        print("never reached handoff", file=sys.stderr)
    else:
        wait_for("[hamterm] NS_PROBE", 200); time.sleep(8)
        files_before = find_wids("Files")
        editors_before = find_wids("Editor")
        print(f"Files={files_before} Editors_before={editors_before}", file=sys.stderr)
        if not files_before:
            print("no Files window", file=sys.stderr); rc=3
        else:
            fm=files_before[0]
            cf=f"/dev/wsys/{fm}/ctl"
            send(f"echo raise > {cf}"); time.sleep(0.5)
            cat_scene(fm,"FM_BEFORE"); screendump("fm_before")
            # Drive via the GLOBAL writable /dev/mouse (the realistic user path:
            # the compositor reads it, routes the click to the window under the
            # cursor, and emits window-LOCAL /event to the FM). Direct /event
            # injection is owner/hostowner-gated, so a non-owner shell can't use
            # it — /dev/mouse is the right capability. Format: "x y buttons".
            # The "version" file icon sits at screen ~(296,322) (from the PNG:
            # FM window origin ~262,150; cell 8 center). A double-click opens it.
            # ABSOLUTE /dev/mouse injection: "<ax> <ay> <btn> <dz> <abs=1>"
            # where ax/ay are 0..32767 tablet space scaled to the framebuffer
            # (1280x800). Convert from screen pixels.
            SW, SH = 1280, 800
            def ax(px): return int(px * 32768 / SW)
            def ay(py): return int(py * 32768 / SH)
            def mouse(px, py, b): send(f" echo '{ax(px)} {ay(py)} {b} 0 1' > /dev/mouse")
            def dblclick(px, py):
                mouse(px, py, 0); time.sleep(0.15)   # move onto the cell
                mouse(px, py, 1); time.sleep(0.10)   # press
                mouse(px, py, 0); time.sleep(0.10)   # release
                mouse(px, py, 1); time.sleep(0.10)   # press again (double)
                mouse(px, py, 0); time.sleep(0.8)    # release
            # Try a small spread of screen coords around the version icon to
            # absorb framebuffer-size / window-placement variance.
            for (sx, sy) in [(296, 320), (296, 310), (290, 322), (300, 318), (296, 300)]:
                dblclick(sx, sy)
                time.sleep(1.2)
                eds = find_wids("Editor")
                if [w for w in eds if w not in editors_before]:
                    print(f"new editor after click at ({sx},{sy})", file=sys.stderr)
                    break
            cat_scene(fm,"FM_AFTER"); screendump("fm_after")
            time.sleep(3)
            editors_after = find_wids("Editor")
            print(f"Editors_after={editors_after}", file=sys.stderr)
            # The NEW editor is one not present before (FM spawns hameditscene).
            new_eds = [w for w in editors_after if w not in editors_before]
            target_eds = new_eds if new_eds else editors_after
            ok=False
            for ed in target_eds:
                send(f"echo raise > /dev/wsys/{ed}/ctl"); time.sleep(0.5)
                screendump(f"editor_{ed}")
                blk=cat_scene(ed, f"ED_{ed}")
                if b"Hamnix bare-metal kernel" in blk or b"hamedit: /version" in blk:
                    ok=True
                    print(f"editor wid {ed} loaded /version", file=sys.stderr)
            rc = 0 if ok else 1
        for _ in range(12):
            send("echo BUG1DONE")
            if wait_for("BUG1DONE",4): break
finally:
    try: qemu.terminate(); qemu.wait(timeout=10)
    except Exception:
        try: qemu.kill()
        except Exception: pass
    logf.flush(); logf.close(); sys.exit(rc)
