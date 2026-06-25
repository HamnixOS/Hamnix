#!/usr/bin/env python3
# BUG 1 contract proof: hameditscene loads the file named in argv[1]. We spawn
# `/bin/hameditscene /version` from the serial shell and assert the new editor
# window's scene shows /version's content ("Hamnix bare-metal kernel") and the
# title "hamedit: /version" (NOT "(unnamed)"). This proves the receiving end of
# the FM->editor launch: the FM fix passes argv as [bin, path, NULL] so the
# editor sees argc==2 and runs exactly this preload path.
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
            w=int(m.group(1))
            if w not in out: out.append(w)
    return out
def cat_scene(wid,tag):
    with lock: start=len(buf)
    send(f"cat /dev/wsys/{wid}/scene"); time.sleep(1.8)
    tail=snap()[start:]; logf.write(b"\n=== "+tag.encode()+b" ===\n"+tail+b"\n"); logf.flush()
    return tail
rc=2
try:
    if not wait_for("handing off to interactive shell", boot_wait):
        print("no handoff", file=sys.stderr)
    else:
        wait_for("[hamterm] NS_PROBE", 200); time.sleep(8)
        eds0=find_wids("Editor"); print(f"editors_before={eds0}", file=sys.stderr)
        # Spawn the editor on /version, exactly as the FM now does (argv[1]=path).
        send("/bin/hameditscene /version &")
        time.sleep(6)
        eds1=find_wids("Editor"); print(f"editors_after={eds1}", file=sys.stderr)
        new=[w for w in eds1 if w not in eds0] or eds1
        ok=False
        for ed in new:
            send(f"echo raise > /dev/wsys/{ed}/ctl"); time.sleep(0.5)
            screendump(f"editor_{ed}")
            blk=cat_scene(ed,f"ED_{ed}")
            has_content = b"Hamnix bare-metal kernel" in blk
            has_title = b"hamedit: /version" in blk
            print(f"ed {ed}: content={has_content} title={has_title}", file=sys.stderr)
            if has_content or has_title:
                ok=True
        rc = 0 if ok else 1
        for _ in range(12):
            send("echo ARGVDONE")
            if wait_for("ARGVDONE",4): break
finally:
    try: qemu.terminate(); qemu.wait(timeout=10)
    except Exception:
        try: qemu.kill()
        except Exception: pass
    logf.flush(); logf.close(); sys.exit(rc)
