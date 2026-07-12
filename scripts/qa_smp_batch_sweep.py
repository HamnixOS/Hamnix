#!/usr/bin/env python3
# scripts/qa_smp_batch_sweep.py — THROWAWAY diagnostic sweep harness for the
# 2026-07-12 SMP/MADT/OOM/bind batch integration QA. NOT a gate; produces
# serial logs + a marker summary per (smp,mem) config. Optionally drives the
# shell over a bidirectional serial socket.
#
# Usage:
#   qa_smp_batch_sweep.py boot   --smp N --mem 2G [--secs 120] --tag NAME
#   qa_smp_batch_sweep.py drive  --smp N --mem 2G --tag NAME    (sends cmds)
import argparse, os, socket, subprocess, sys, time, tempfile, shutil, signal, re

IMG = "build/hamnix-installer.img"
OVMF = "/usr/share/ovmf/OVMF.fd"
READY = b"handing off to interactive shell"

def find_ovmf():
    for p in (OVMF, "/usr/share/OVMF/OVMF_CODE_4M.fd", "/usr/share/OVMF/OVMF_CODE.fd"):
        if os.path.exists(p):
            return p
    sys.exit("no OVMF")

def qemu_base(smp, mem, ovmf_rw, extra):
    return [
        "qemu-system-x86_64", "-enable-kvm", "-cpu", "host",
        "-bios", ovmf_rw,
        "-drive", f"file={IMG},format=raw,if=virtio",
        "-m", mem, "-smp", str(smp),
        "-vga", "std", "-display", "none",
        "-no-reboot", "-monitor", "none",
    ] + extra

def boot_readonly(smp, mem, secs, logpath):
    ovmf_rw = tempfile.mktemp(suffix=".fd")
    shutil.copy(find_ovmf(), ovmf_rw)
    cmd = qemu_base(smp, mem, ovmf_rw, ["-serial", f"file:{logpath}"])
    print(f"[sweep] BOOT smp={smp} mem={mem} secs={secs} -> {logpath}", flush=True)
    p = subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    deadline = time.time() + secs
    try:
        while time.time() < deadline:
            if p.poll() is not None:
                print(f"[sweep] qemu exited early rc={p.returncode}", flush=True)
                break
            time.sleep(2)
    finally:
        if p.poll() is None:
            p.send_signal(signal.SIGTERM)
            try: p.wait(5)
            except Exception: p.kill()
        stderr = p.stderr.read().decode(errors="replace") if p.stderr else ""
        if stderr.strip():
            with open(logpath, "ab") as f:
                f.write(b"\n---QEMU STDERR---\n" + stderr.encode())
        os.unlink(ovmf_rw)

def boot_drive(smp, mem, logpath, cmds, tail_secs=45):
    ovmf_rw = tempfile.mktemp(suffix=".fd")
    shutil.copy(find_ovmf(), ovmf_rw)
    sockpath = tempfile.mktemp(suffix=".sock")
    # QEMU is the socket SERVER (creates sockpath); python connects as the
    # CLIENT once qemu has created it. (Both-server => nobody connects.)
    cmd = qemu_base(smp, mem, ovmf_rw, ["-serial", f"unix:{sockpath},server=on,wait=off"])
    print(f"[sweep] DRIVE smp={smp} mem={mem} -> {logpath}", flush=True)
    p = subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    log = open(logpath, "wb")
    conn = None
    deadline0 = time.time() + 60
    while time.time() < deadline0:
        try:
            conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            conn.connect(sockpath); break
        except (FileNotFoundError, ConnectionRefusedError):
            conn = None; time.sleep(0.5)
    try:
        if conn is None:
            print("[sweep] ERROR could not connect to qemu serial socket", flush=True)
            return
        conn.setblocking(False)
        buf = b""
        ready = False
        sent = False
        deadline = time.time() + 220
        send_at = None
        while time.time() < deadline:
            try:
                data = conn.recv(65536)
                if data:
                    log.write(data); log.flush(); buf += data
            except BlockingIOError:
                time.sleep(0.2)
            except Exception:
                break
            if not ready and READY in buf:
                ready = True
                send_at = time.time() + 4  # let prompt settle
                print("[sweep] boot-ready marker seen", flush=True)
            if ready and not sent and time.time() >= send_at:
                # hamsh drops the FIRST serial cmd -> send a priming newline.
                conn.sendall(b"\r\n")
                time.sleep(1.0)
                for c in cmds:
                    conn.sendall(c.encode() + b"\r\n")
                    time.sleep(2.5)
                sent = True
                deadline = time.time() + tail_secs
                print("[sweep] commands sent", flush=True)
        if not ready:
            print("[sweep] WARNING boot-ready never seen", flush=True)
    finally:
        log.close()
        if conn is not None:
            try: conn.close()
            except Exception: pass
        if p.poll() is None:
            p.send_signal(signal.SIGTERM)
            try: p.wait(5)
            except Exception: p.kill()
        for f in (ovmf_rw, sockpath):
            try: os.unlink(f)
            except Exception: pass

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("mode", choices=["boot", "drive"])
    ap.add_argument("--smp", type=int, required=True)
    ap.add_argument("--mem", required=True)
    ap.add_argument("--secs", type=int, default=120)
    ap.add_argument("--tag", required=True)
    a = ap.parse_args()
    os.makedirs("/tmp/claude-1000/-home-david-Hamnix/6527df28-f4f2-4b9a-9fbf-ae9d9c16b094/scratchpad/logs", exist_ok=True)
    logpath = f"/tmp/claude-1000/-home-david-Hamnix/6527df28-f4f2-4b9a-9fbf-ae9d9c16b094/scratchpad/logs/{a.tag}.log"
    if a.mode == "boot":
        boot_readonly(a.smp, a.mem, a.secs, logpath)
    else:
        cmds = [
            "ls /",
            "cat /proc/cpuinfo",
            "cat /proc/meminfo",
            "bind /nonexistent-src /mnt-bogus",
            "bind /bin /mnt-real",
            "echo BIND_DONE_MARKER",
        ]
        boot_drive(a.smp, a.mem, logpath, cmds)
    print(f"[sweep] done -> {logpath}", flush=True)

if __name__ == "__main__":
    main()
