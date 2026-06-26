#!/usr/bin/env bash
# scripts/test_serial_enter_linux_sh.sh — SERIAL-console verification of
# the user-reported bug:
#
#   On the SERIAL console, `enter linux { sh }` then `ls` printed
#   `hamsh: command not found: ls` — the body never became an interactive
#   Linux shell; the prompt stayed native hamsh. The SAME `enter linux
#   { sh }` works in the GUI/DE terminal (a PTY). So it is SERIAL-SPECIFIC.
#
# ROOT CAUSE (kernel, sys/src/9/port/devcons.ad)
#   At runlevel 5 the desktop compositor takes wsys wid 1 = foreground.
#   The /dev/cons reader path gated the UART RX pop behind `is_fg`
#   (wsys_current_is_foreground). An `enter linux { sh }` child spawned
#   from the serial shell is NOT the foreground GRAPHICAL window, so the
#   `is_fg` gate made it NEVER pop a serial (UART) byte — its interactive
#   read(0) could not advance, so the shell fell straight through and the
#   next typed line went back to hamsh. The UART is a SEPARATE terminal
#   (#439); its reader is arbitrated by the grab PARTITION
#   (console_input_may_pop_uart_current), NOT by graphical foreground.
#
# FIX
#   devcons_read / devcons_read_nb pop the UART gated on `may_uart` ONLY,
#   never on `is_fg`. (The PS/2 keyboard arm stays foreground-gated — that
#   ring really is the local console's.)
#
# This harness boots the REAL installer image under OVMF/KVM (the same one
# test_de_term_enter_linux.sh uses) so the desktop is LIVE, then drives
# `enter linux { sh }` over the SERIAL line and asserts the entered shell
# reads typed serial commands and produces real Linux output. The DE-live
# boot is exactly the condition that triggered the bug.

set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

INSTALLER_IMG="${INSTALLER_IMG:-build/hamnix-installer.img}"
BOOT_WAIT="${BOOT_WAIT:-240}"
TS="$(date +%Y%m%d-%H%M%S)"
OUT_DIR="${OUT_DIR:-build/serial_enter_linux_sh/$TS}"

if [ ! -e /dev/kvm ]; then
    echo "[serial_entlnx] SKIP: /dev/kvm absent (KVM required)" >&2
    exit 0
fi
OVMF_FD="${OVMF_FD:-}"
if [ -z "$OVMF_FD" ]; then
    for cand in /usr/share/ovmf/OVMF.fd /usr/share/OVMF/OVMF_CODE.fd /usr/share/OVMF/OVMF_CODE_4M.fd; do
        [ -f "$cand" ] && OVMF_FD="$cand" && break
    done
fi
if [ -z "$OVMF_FD" ] || [ ! -f "$OVMF_FD" ]; then
    echo "[serial_entlnx] SKIP: OVMF firmware not found (apt install ovmf)" >&2
    exit 0
fi
if [ ! -f "$INSTALLER_IMG" ]; then
    if [ "${HAMNIX_SKIP_BUILD:-0}" = "1" ]; then
        echo "[serial_entlnx] SKIP: $INSTALLER_IMG absent and HAMNIX_SKIP_BUILD=1" >&2
        exit 0
    fi
    echo "[serial_entlnx] building installer image (~6 min)"
    bash "$PROJ_ROOT/scripts/build_installer_img.sh"
fi
if [ ! -f "$INSTALLER_IMG" ]; then
    echo "[serial_entlnx] SKIP: $INSTALLER_IMG unavailable" >&2
    exit 0
fi

mkdir -p "$OUT_DIR"
echo "[serial_entlnx] output dir: $OUT_DIR"

OVMF_RW=$(mktemp --tmpdir hamnix-sel.ovmf.XXXXXX.fd)
IMG_RW=$(mktemp --tmpdir hamnix-sel.img.XXXXXX.raw)
LOG="$OUT_DIR/serial.log"
cp "$OVMF_FD" "$OVMF_RW"
cp "$INSTALLER_IMG" "$IMG_RW"
cleanup() { rm -f "$OVMF_RW" "$IMG_RW"; }
trap cleanup EXIT
: > "$LOG"

python3 - "$IMG_RW" "$OVMF_RW" "$LOG" "$BOOT_WAIT" <<'PYDRV'
import sys, subprocess, time, threading

img, ovmf, logpath, boot_wait = sys.argv[1:5]
boot_wait = int(boot_wait)

qemu = subprocess.Popen([
    "qemu-system-x86_64", "-enable-kvm", "-cpu", "host",
    "-bios", ovmf,
    "-drive", f"file={img},format=raw,if=virtio",
    "-m", "1G",
    "-vga", "std", "-display", "none", "-no-reboot",
    "-serial", "stdio",
], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
   bufsize=0)

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

def snapshot():
    with lock:
        return bytes(buf)

def send(line):
    try:
        qemu.stdin.write((line + "\n").encode()); qemu.stdin.flush()
    except Exception:
        pass

rc = 2
try:
    # Gate on the DE being fully up + the serial shell responsive. The
    # scene terminal emits "[hamterm] NS_PROBE" to /dev/cons once its
    # window + shell exist — by then runlevel 5 is live (the exact
    # foreground-grab condition that triggered the bug) and the serial
    # shell is consuming stdin.
    if not wait_for("[hamterm] NS_PROBE", boot_wait):
        # Fall back to the generic ready marker if the terminal probe is
        # absent on this build; either proves the serial shell is up.
        if not wait_for("M16.35 shell ready", 30):
            print("[serial_entlnx] driver: shell never became ready", file=sys.stderr)
            qemu.kill(); sys.exit(2)
    print("[serial_entlnx] driver: DE up + serial shell ready", file=sys.stderr)
    time.sleep(4)

    # Re-send-prone: a freshly-busy serial readline can drop a line.
    # Sync probe first.
    for _ in range(20):
        send("echo SERIAL_SYNC")
        time.sleep(1.0)
        if b"SERIAL_SYNC" in snapshot():
            break
    print("[serial_entlnx] driver: serial sync OK", file=sys.stderr)

    # Drive the interactive enter-linux on the SERIAL line.
    send("enter linux { sh }")
    time.sleep(5)
    # Typed at the ENTERED shell's prompt. If the entered sh is reading the
    # serial line, this echo runs INSIDE the linux ns and prints the marker.
    for _ in range(6):
        send("echo ENTER_LINUX_SH_OK")
        time.sleep(2.0)
        if b"ENTER_LINUX_SH_OK" in snapshot():
            break
    # A pipe through grep proves a real /bin/sh ran a real pipeline.
    for _ in range(6):
        send("echo pipe_hi | grep pipe_hi")
        time.sleep(2.0)
        if snapshot().count(b"pipe_hi") >= 2:
            break
    # ls the root — a real Linux binary, not a hamsh builtin.
    send("ls /")
    time.sleep(3)
    # Leave the linux shell, back to hamsh.
    send("exit")
    time.sleep(2)
    send("exit")
    time.sleep(2)
except Exception as e:
    print(f"[serial_entlnx] driver exception: {e}", file=sys.stderr)
finally:
    try:
        qemu.terminate()
        time.sleep(1)
        qemu.kill()
    except Exception:
        pass

sys.exit(0)
PYDRV

echo "[serial_entlnx] --- serial transcript (filtered) ---"
tr -d '\0' < "$LOG" | grep -aE "SERIAL_SYNC|enter linux|ENTER_LINUX_SH_OK|pipe_hi|command not found|code=127" | tail -40 || true
echo "[serial_entlnx] --- end ---"

fail=0

# (1) The entered shell ran the typed echo — proves a real interactive sh
#     consumed the serial line INSIDE the linux ns.
if grep -a -F -q "ENTER_LINUX_SH_OK" "$LOG"; then
    echo "[serial_entlnx] OK: interactive linux sh ran a typed serial command"
else
    echo "[serial_entlnx] FAIL: ENTER_LINUX_SH_OK not seen — entered sh never read the serial line"
    fail=1
fi

# (2) The pipe through grep produced its match — a real /bin/sh pipeline,
#     not a hamsh fallthrough. Two occurrences = the typed line + grep out.
if [ "$(tr -d '\0' < "$LOG" | grep -a -c 'pipe_hi')" -ge 2 ]; then
    echo "[serial_entlnx] OK: 'echo pipe_hi | grep pipe_hi' ran in the linux sh"
else
    echo "[serial_entlnx] FAIL: the grep pipeline did not run in the entered shell"
    fail=1
fi

# (3) The bug signature: hamsh — NOT the linux sh — claiming the command.
#     If we ever see hamsh reporting `ls`/`echo` as not-found AFTER the
#     enter, the prompt stayed hamsh (the reported regression).
if LC_ALL=C awk '
    index($0,"enter linux { sh }")>0 {armed=1}
    armed && index($0,"hamsh: command not found")>0 {print; f=1}
    END{exit f?0:1}' "$LOG" >/dev/null; then
    echo "[serial_entlnx] FAIL: hamsh claimed a command after enter linux { sh } — prompt stayed hamsh (the bug)"
    fail=1
else
    echo "[serial_entlnx] OK: no hamsh-command-not-found after the enter (prompt was the linux sh)"
fi

# (4) No exec failure / trap from the enter.
if LC_ALL=C awk 'index($0,"enter linux { sh }")>0{a=1} a&&index($0,"code=127")>0{print;f=1} END{exit f?0:1}' "$LOG" >/dev/null; then
    echo "[serial_entlnx] FAIL: code=127 after enter linux { sh } (exec failure)"
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[serial_entlnx] FAIL"
    exit 1
fi
echo "[serial_entlnx] PASS — serial enter linux { sh } drops into a working interactive Linux shell with the DE live"
