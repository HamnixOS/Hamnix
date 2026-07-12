#!/usr/bin/env python3
# THROWAWAY: measure guest-uptime advance vs wall-clock at a given -smp.
# Boots the installer under KVM with serial->file, polls the file and
# records wall time when each new [hamsh-alive] tick appears, then reports
# guest-seconds-per-wall-second between the first and last observed tick
# (a delta of two ticks, so boot overhead cancels out).
import os, subprocess, sys, time, tempfile, shutil, signal, re

IMG = "build/hamnix-installer.img"
def ovmf():
    for p in ("/usr/share/ovmf/OVMF.fd","/usr/share/OVMF/OVMF_CODE_4M.fd"):
        if os.path.exists(p): return p
    sys.exit("no ovmf")

smp = int(sys.argv[1]); mem = sys.argv[2]; window = int(sys.argv[3]) if len(sys.argv)>3 else 70
rw = tempfile.mktemp(suffix=".fd"); shutil.copy(ovmf(), rw)
logp = tempfile.mktemp(suffix=".log")
cmd = ["qemu-system-x86_64","-enable-kvm","-cpu","host","-bios",rw,
       "-drive",f"file={IMG},format=raw,if=virtio","-m",mem,"-smp",str(smp),
       "-vga","std","-display","none","-no-reboot","-monitor","none",
       "-serial",f"file:{logp}"]
p = subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
pat = re.compile(r"hamsh-alive\] tick=(\d+) uptime=(\d+)s")
seen=set(); ticks=[]  # (wall, tick, uptime)
start=time.time(); t_first=None
try:
    while True:
        now=time.time()
        if t_first and now - t_first > window: break
        if now - start > 240: break
        if p.poll() is not None: break
        try:
            with open(logp,"r",errors="replace") as f: data=f.read()
        except FileNotFoundError:
            data=""
        for m in pat.finditer(data):
            tk=int(m.group(1))
            if tk in seen: continue
            seen.add(tk)
            w=time.time()
            ticks.append((w,tk,int(m.group(2))))
            if t_first is None: t_first=w
        time.sleep(0.25)
finally:
    if p.poll() is None:
        p.send_signal(signal.SIGTERM)
        try: p.wait(5)
        except Exception: p.kill()
    for f in (rw,logp):
        try: os.unlink(f)
        except Exception: pass

if len(ticks)>=3:
    w0,t0,u0=ticks[0]; w1,t1,u1=ticks[-1]
    wall=w1-w0; gup=u1-u0
    rate=gup/wall if wall>0 else 0
    print(f"smp={smp} mem={mem}: nticks={len(ticks)} tick_range={t0}..{t1} "
          f"guest_uptime_delta={gup}s wall_delta={wall:.1f}s RATE={rate:.2f}x")
else:
    print(f"smp={smp} mem={mem}: INCONCLUSIVE nticks={len(ticks)}")
