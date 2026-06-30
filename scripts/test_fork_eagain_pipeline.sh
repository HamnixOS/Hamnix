#!/usr/bin/env bash
# scripts/test_fork_eagain_pipeline.sh
#
# Regression guard for the user-reported fork-EAGAIN wedge:
#
#   /bin # ls | grep cat
#   /bin # ls | grep cat
#   sh: can't fork: Resource temporarily unavailable
#
# In `enter linux { sh }`, running the pipeline `ls | grep cat` repeatedly
# must NOT exhaust kernel resources. Each pipeline forks two children, each
# a fork+exec(busybox)+exit that the shell wait4-reaps.
#
# ROOT CAUSE (fixed): task_reap defers the task-slot free to an RCU grace
# period but left the slot in STATE_EXITED in the meantime. Every zombie
# scan (_wait_any_zombie_child / _has_live_child / reap_orphan_zombies / the
# thread-group sweep) keys on STATE_EXITED, so a just-reaped child was
# re-found and re-reaped — wait4(-1) spun forever returning the same dead
# pid, the shell's waitforjob never completed, slots/pids never recycled,
# and the next fork hit -EAGAIN. The fix publishes a reaped slot as a
# distinct STATE_REAPING (invisible to wait/reap, still off the freelist
# until the RCU callback flips it FREE). A companion orphan sweep in
# reap_orphan_zombies also reclaims non-detached zombies whose parent died.
#
# This drives the ACTUAL repro over the SERIAL console of a DE-live boot
# (the condition the bug needs) under KVM, and asserts:
#   (1) no "can't fork" / -EAGAIN across many pipelines,
#   (2) the final marker prints (the shell survived all reps),
#   (3) no kernel trap.
# Surviving 12+ pipelines without -EAGAIN is itself proof the per-child
# resources (slots, pids, pages) return to baseline each pipeline — a leak
# would exhaust them within a handful of reps.

. "$(dirname "$0")/_build_lock.sh"
. "$(dirname "$0")/_ensure_ubin.sh"
. "$(dirname "$0")/_kernel_iso.sh"

set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf
REPS="${FORK_EAGAIN_REPS:-12}"
BOOT_WAIT="${FORK_EAGAIN_BOOT_WAIT:-300}"

ensure_ubin_or_skip test_fork_eagain_pipeline u_busybox_musl musl_busybox

if [ ! -e /dev/kvm ]; then
    echo "[test_fork_eagain_pipeline] SKIP: /dev/kvm absent (KVM required for a" \
         "timely DE-live serial boot)" >&2
    exit 0
fi

echo "[test_fork_eagain_pipeline] (1/5) Build userland + modules"
bash scripts/build_user.sh >/dev/null
bash scripts/build_modules.sh >/dev/null

echo "[test_fork_eagain_pipeline] (2/5) Build default initramfs"
python3 scripts/build_initramfs.py >/dev/null

echo "[test_fork_eagain_pipeline] (3/5) Rebuild kernel image"
mkdir -p build
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

echo "[test_fork_eagain_pipeline] (4/5) Wrap kernel in a GRUB ISO"
ISO="$(kernel_iso "$ELF")"
[ -f "$ISO" ] || { echo "[test_fork_eagain_pipeline] ERROR: ISO not built" >&2; exit 1; }

echo "[test_fork_eagain_pipeline] (5/5) Boot (KVM, DE live) + drive ${REPS}x 'ls | grep cat' over serial"

LOG="${FORK_EAGAIN_LOG:-/tmp/fork_eagain_full.log}"
: > "$LOG"

python3 - "$ISO" "$LOG" "$BOOT_WAIT" "$REPS" <<'PYDRV'
import sys, subprocess, time, threading

iso, logpath, boot_wait, reps = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4])

qemu = subprocess.Popen([
    "qemu-system-x86_64", "-accel", "kvm", "-cpu", "host",
    "-cdrom", iso, "-boot", "d",
    "-smp", "2", "-nographic", "-no-reboot",
    "-m", "2G", "-monitor", "none", "-serial", "stdio",
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
    m = marker.encode()
    deadline = time.time() + timeout
    while time.time() < deadline:
        with lock:
            if m in buf:
                return True
        if qemu.poll() is not None:
            return False
        time.sleep(0.5)
    return False

def snap():
    with lock:
        return bytes(buf)

def send(line):
    try:
        qemu.stdin.write((line + "\n").encode()); qemu.stdin.flush()
    except Exception:
        pass

try:
    # Gate on the DE terminal probe (runlevel 5 fully up = the foreground
    # condition the bug needs), with the generic shell banner as a fallback.
    if not wait_for("[hamterm] NS_PROBE", boot_wait):
        if not wait_for("M16.35 shell ready", 30):
            print("DRIVER: shell never became ready", file=sys.stderr)
            qemu.kill(); sys.exit(2)
    # rc.boot keeps running for a while AFTER NS_PROBE; the serial readline only
    # starts consuming stdin once runlevel 5 is fully entered. Wait for that
    # settle marker (best-effort) before the sync handshake.
    wait_for("rc.boot: entered runlevel 5", 90)
    time.sleep(4)

    # Serial sync: a freshly-busy readline can drop the first line; re-send an
    # idempotent probe until it echoes back. Generous window — on a loaded host
    # the serial shell can take a while to become the UART reader.
    synced = False
    for _ in range(120):
        send("echo SERIAL_SYNC")
        time.sleep(1.0)
        if b"SERIAL_SYNC" in snap():
            synced = True
            break
    if not synced:
        print("DRIVER: SERIAL_SYNC never echoed", file=sys.stderr)

    send("enter linux { sh }")
    time.sleep(5)
    for _ in range(6):
        send("echo ENTER_LINUX_SH_OK")
        time.sleep(2.0)
        if b"ENTER_LINUX_SH_OK" in snap():
            break

    for i in range(reps):
        send("ls | grep cat")
        time.sleep(3.0)
        s = snap()
        if b"can't fork" in s or b"Resource temporarily unavailable" in s:
            print(f"DRIVER: EAGAIN at rep {i+1}", file=sys.stderr)
            break

    for _ in range(4):
        send("echo PIPELINE_DONE_OK")
        time.sleep(2.0)
        if b"PIPELINE_DONE_OK" in snap():
            break
    send("exit"); time.sleep(2)
    send("exit"); time.sleep(2)
except Exception as e:
    print(f"DRIVER exception: {e}", file=sys.stderr)
finally:
    try:
        qemu.terminate(); time.sleep(1); qemu.kill()
    except Exception:
        pass
sys.exit(0)
PYDRV

echo "[test_fork_eagain_pipeline] full log saved at: $LOG"
echo "[test_fork_eagain_pipeline] --- captured transcript (filtered) ---"
tr -d '\0' < "$LOG" | grep -aE "SERIAL_SYNC|ENTER_LINUX_SH_OK|can't fork|Resource temporarily|PIPELINE_DONE_OK|TRAP: vector" | tail -40 || true
echo "[test_fork_eagain_pipeline] --- end ---"

fail=0

if grep -a -E -q "can't fork|Resource temporarily unavailable|Cannot fork" "$LOG"; then
    echo "[test_fork_eagain_pipeline] FAIL: fork-EAGAIN observed during repeated pipelines"
    grep -a -E -n "can't fork|Resource temporarily unavailable|Cannot fork" "$LOG" | head -5 || true
    fail=1
else
    echo "[test_fork_eagain_pipeline] OK: no fork-EAGAIN across ${REPS} pipelines"
fi

if grep -a -F -q "ENTER_LINUX_SH_OK" "$LOG"; then
    echo "[test_fork_eagain_pipeline] OK: interactive linux sh attached over serial"
else
    echo "[test_fork_eagain_pipeline] FAIL: enter linux { sh } never became interactive"
    fail=1
fi

if grep -a -F -q "PIPELINE_DONE_OK" "$LOG"; then
    echo "[test_fork_eagain_pipeline] OK: shell survived all pipelines and ran the final command"
else
    echo "[test_fork_eagain_pipeline] FAIL: PIPELINE_DONE_OK not seen — shell did not survive"
    fail=1
fi

if grep -a -F -q "TRAP: vector" "$LOG"; then
    echo "[test_fork_eagain_pipeline] FAIL: CPU exception observed"
    grep -a -F "TRAP: vector" "$LOG" | head -5 || true
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_fork_eagain_pipeline] FAIL"
    exit 1
fi
echo "[test_fork_eagain_pipeline] PASS"
exit 0
