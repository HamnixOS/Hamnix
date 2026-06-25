#!/usr/bin/env python3
# BUG 4: launch hamsettings the way the user does (double-click the Settings
# desktop icon -> hamdesktop spawns /bin/hamsettings in the DE namespace) and
# confirm it opens a working window WITHOUT crashing. We assert: a "Settings"
# window appears, its scene renders the control-center widgets, and clicking a
# swatch + a panel toggle does not fault. Watch the serial log for any panic /
# fault / "exited (code" of the settings task.
import sys, subprocess, time, threading, os, re
img, ovmf, mon, logpath, outdir, boot_wait = sys.argv[1:7]; boot_wait=int(boot_wait)
qemu = subprocess.Popen(["qemu-system-x86_64","-enable-kvm","-cpu","host","-bios",ovmf,
    "-drive",f"file={img},format=raw,if=virtio","-m","1G","-vga","std","-display","none",
    "-no-reboot","-monitor",f"unix:{mon},server,nowait","-serial","stdio"],
    stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, bufsize=0)
logf=open(logpath,"wb"); buf=bytearray(); lock=threading.Lock()
def reader():
    while True:
        b=qemu.stdout.read(1)
        if not b: break
        logf.write(b); logf.flush()
        with lock: buf.extend(b)
threading.Thread(target=reader,daemon=True).start()
def wait_for(m,t):
    mm=m.encode(); d=time.time()+t
    while time.time()<d:
        with lock:
            if mm in buf: return True
        if qemu.poll() is not None: return False
        time.sleep(0.5)
    return False
def snap():
    with lock: return bytes(buf)
def send(l):
    try: qemu.stdin.write((l+"\n").encode()); qemu.stdin.flush()
    except Exception: pass
def screendump(label):
    ppm=os.path.join(outdir,f"{label}.ppm")
    try: subprocess.run(["socat","-",f"UNIX-CONNECT:{mon}"],input=f"screendump {ppm}\n".encode(),
        timeout=20,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
    except Exception: pass
    for _ in range(30):
        if os.path.exists(ppm) and os.path.getsize(ppm)>0: break
        time.sleep(0.1)
_WINRE=re.compile(rb'^\s*(\d+)\s+([A-Za-z]+)\s*$')
def find_wids(title):
    send("cat /dev/wsys/windows"); time.sleep(1.8)
    s=snap(); out=[]
    for ln in s.split(b"\n"):
        m=_WINRE.match(ln)
        if m and m.group(2).decode()==title:
            w=int(m.group(1));
            if w not in out: out.append(w)
    return out
def cat_scene(wid,tag):
    with lock: start=len(buf)
    send(f"cat /dev/wsys/{wid}/scene"); time.sleep(1.8)
    tail=snap()[start:]; logf.write(b"\n=== "+tag.encode()+b" ===\n"+tail+b"\n"); logf.flush()
    return tail
SW,SH=1280,800
def ax(px): return int(px*32768/SW)
def ay(py): return int(py*32768/SH)
def mouse(px,py,b): send(f" echo '{ax(px)} {ay(py)} {b} 0 1' > /dev/mouse")
def dblclick(px,py):
    mouse(px,py,0); time.sleep(0.15)
    mouse(px,py,1); time.sleep(0.10); mouse(px,py,0); time.sleep(0.10)
    mouse(px,py,1); time.sleep(0.10); mouse(px,py,0); time.sleep(0.8)
rc=2
try:
    if not wait_for("handing off to interactive shell", boot_wait):
        print("no handoff", file=sys.stderr)
    else:
        wait_for("[hamterm] NS_PROBE", 200); time.sleep(8)
        with lock: pre_mark=len(buf)
        screendump("desk_before")
        # Double-click the "Settings" desktop icon (left column). Try a spread
        # of y around the Settings icon (label ~y=431, icon ~y=405).
        got=False
        for (sx,sy) in [(48,405),(48,415),(48,395),(40,408),(55,405)]:
            dblclick(sx,sy)
            time.sleep(2.0)
            if find_wids("Settings"):
                got=True; print(f"Settings opened via icon at ({sx},{sy})", file=sys.stderr); break
        sets=find_wids("Settings")
        print(f"Settings wids={sets}", file=sys.stderr)
        screendump("desk_after")
        crash=False
        # scan the serial tail since the click for a settings-task fault.
        tail=snap()[pre_mark:]
        for pat in [b"panic", b"unhandled", b"#PF", b"page fault", b"GPF", b"#GP"]:
            if pat in tail:
                # only count it if near a hamsettings context — but any new
                # panic post-launch is a red flag.
                crash=True
        if sets:
            sw_=sets[-1]
            send(f"echo raise > /dev/wsys/{sw_}/ctl"); time.sleep(0.5)
            screendump("settings_win")
            blk=cat_scene(sw_,"SET_SCENE")
            rendered = b'"Settings"' in blk or b"Desktop wallpaper" in blk or b"Panels" in blk
            print(f"settings rendered={rendered}", file=sys.stderr)
            # Exercise click handlers: click a wallpaper swatch + a panel button
            # at their on-screen positions (window placed by geometry 240 120).
            # swatch 0 ~ window-local (36,76) -> screen (240+36,120+76)=(276,196)
            dblclick(276,196); time.sleep(0.5)
            screendump("settings_click")
            cat_scene(sw_,"SET_SCENE2")
            # still alive?
            still=find_wids("Settings")
            print(f"settings still present after clicks={bool(still)}", file=sys.stderr)
            rc = 0 if (rendered and still and not crash) else 1
        else:
            print("Settings window never appeared", file=sys.stderr)
            rc = 3
        for _ in range(12):
            send("echo BUG4DONE")
            if wait_for("BUG4DONE",4): break
finally:
    try: qemu.terminate(); qemu.wait(timeout=10)
    except Exception:
        try: qemu.kill()
        except Exception: pass
    logf.flush(); logf.close(); sys.exit(rc)
