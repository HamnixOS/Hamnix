#!/usr/bin/env bash
# scripts/test_kbd_sigint.sh — Ctrl-C on the PS/2 keyboard path must
# deliver SIGINT to the foreground child.
#
# Bug being guarded against:
#
# Two console input paths exist and historically handled Ctrl-C
# asymmetrically:
#
#   * UART (serial console, -nographic). early_8250::uart_drain_hw_to_fifo
#     plucks 0x03 OUT of the byte stream and signals up its return
#     value; uart_rx_irq (vector 36) then calls
#     signal_post_to_foreground(SIGINT). Already correct.
#
#   * atkbd (PS/2 keyboard / QEMU graphics window). atkbd_apply_ctrl
#     translated Ctrl+'c' into 0x03 and pushed the byte into kbd_rx —
#     but NOTHING called signal_post_to_foreground. So a foreground
#     child like /bin/yes that never reads stdin received the byte at
#     the kbd FIFO and ignored it, and the user could not interrupt
#     it from a real PC keyboard / QEMU's graphics window.
#
# The fix posts SIGINT to the foreground the moment Ctrl-byte
# translation produces 0x03 inside atkbd_process_byte. This test
# proves that fix works end-to-end through the actual i8042 hardware
# model — not just the synthetic-scancode self-test that
# test_atkbd_ext.sh covers.
#
# Test shape:
#   1. Boot hamsh as /init. Attach -monitor to a unix socket and
#      -serial to another unix socket, so the harness can read+write
#      the console AND drive `sendkey` on the side.
#   2. Wait for the prompt, then send `/bin/yes\n` over the serial
#      socket. hamsh forks/execs /bin/yes; the child loops on
#      sys_write(1, ...) and never reads stdin. (Important: this is
#      why a Ctrl-byte arriving via the UART would not help — the
#      child doesn't drain it. But the UART RX IRQ already posts
#      SIGINT independently. So we deliberately use the QEMU MONITOR
#      `sendkey ctrl-c` to drive the PS/2 keyboard path, NOT the
#      serial socket.)
#   3. Inject `sendkey ctrl-c` via the QEMU monitor. QEMU routes this
#      to the virtual i8042 controller, which raises IRQ 1 and the
#      kernel's atkbd_irq_handler drains the scancodes — exactly the
#      code path the bug lived on.
#   4. Assert: the child exited with code 130 (= 128 + SIGINT/2),
#      hamsh survived (`exit` returns code 0), no CPU trap fired.
#
# Pass marker: [test_kbd_sigint] PASS
# Fail marker: [test_kbd_sigint] FAIL

. "$(dirname "$0")/_build_lock.sh"

set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf

echo "[test_kbd_sigint] (1/4) Build userland (hamsh + yes)"
bash scripts/build_user.sh >/dev/null
bash scripts/build_modules.sh >/dev/null

echo "[test_kbd_sigint] (2/4) Swap /init = hamsh in initramfs"
INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py >/dev/null

echo "[test_kbd_sigint] (3/4) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

echo "[test_kbd_sigint] (4/4) Boot QEMU, drive PS/2 Ctrl-C via monitor sendkey"

LOG=$(mktemp)
MON=$(mktemp -u)
SER=$(mktemp -u)

QPID=""
cleanup() {
    if [ -n "$QPID" ]; then
        kill "$QPID" 2>/dev/null || true
        wait "$QPID" 2>/dev/null || true
    fi
    rm -f "$LOG" "$MON" "$SER"
    INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1 || true
}
trap cleanup EXIT

# Boot QEMU. Monitor + serial each go to their own unix socket
# (server,nowait so QEMU is the listener and the harness is the
# client — matches scripts/test_ehci_kbd.sh's monitor pattern).
# `-nographic` is left OFF on purpose: we are exercising the PS/2
# keyboard, and `sendkey` needs to drive a virtual input controller
# regardless of the display. `-display none` suppresses any window
# while keeping the i8042 attached.
qemu-system-x86_64 \
    -kernel "$ELF" \
    -smp 2 \
    -display none \
    -no-reboot \
    -m 256M \
    -monitor unix:"$MON",server,nowait \
    -serial unix:"$SER",server,nowait \
    >/dev/null 2>&1 &
QPID=$!

# Wait (bounded) for both sockets to materialise.
for _ in $(seq 1 80); do
    [ -S "$MON" ] && [ -S "$SER" ] && break
    sleep 0.25
done
if [ ! -S "$MON" ] || [ ! -S "$SER" ]; then
    echo "[test_kbd_sigint] FAIL: QEMU sockets did not appear" >&2
    exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
    echo "[test_kbd_sigint] SKIP: python3 unavailable" >&2
    exit 0
fi

# Drive the scenario from python: connect to both sockets, type
# `/bin/yes`, wait for output, fire `sendkey ctrl-c`, then `exit`.
# The python script writes everything seen on the serial socket to
# LOG so the bash assertions below can grep it.
python3 - "$MON" "$SER" "$LOG" <<'PYEOF'
import socket, sys, time

mon_path, ser_path, log_path = sys.argv[1], sys.argv[2], sys.argv[3]

def connect(p):
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    for _ in range(60):
        try:
            s.connect(p); return s
        except OSError:
            time.sleep(0.25)
    raise RuntimeError(f"could not connect to {p}")

mon = connect(mon_path)
ser = connect(ser_path)
ser.setblocking(False)

log = open(log_path, "wb")

def pump(seconds):
    """Drain pending serial bytes into the log for `seconds` wall-clock."""
    end = time.monotonic() + seconds
    while time.monotonic() < end:
        try:
            data = ser.recv(8192)
            if not data:
                return
            log.write(data); log.flush()
        except BlockingIOError:
            time.sleep(0.05)

# 1. Wait for hamsh to reach its prompt.
pump(6.0)

# 2. Launch /bin/yes. hamsh forks and execs it.
ser.sendall(b"/bin/yes\n")
# Let it produce some output before we interrupt — that proves the
# child actually ran, AND it gives the scheduler something to mark
# foreground.
pump(2.0)

# 3. Fire PS/2 Ctrl-C via the QEMU monitor. `sendkey ctrl-c` is HMP
#    shorthand for LCtrl+'c'; QEMU translates it to scancodes on the
#    i8042 line, IRQ 1 fires, atkbd_irq_handler drains them, and the
#    Ctrl-byte translation produces 0x03 — at which point the fix
#    under test posts SIGINT to the foreground.
mon.sendall(b"sendkey ctrl-c\n")

# 4. Give the kernel time to deliver SIGINT, run the default-action
#    exit path, and emit the "task: pid N exited (code=130)" notice.
pump(4.0)

# 5. Send a bare newline to give hamsh's line editor a fresh prompt
#    (it consumes 0x03 as "discard the line"), then `exit 0` so the
#    box halts cleanly. `exit` with no arg inherits the LAST command's
#    status (which is 130 here because the previous waitpid returned
#    SIGINT-killed yes); using `exit 0` makes "hamsh survived" testable
#    without confusing it with "hamsh was SIGINT'd directly".
ser.sendall(b"\n")
pump(0.5)
ser.sendall(b"exit 0\n")
pump(3.0)

log.close(); mon.close(); ser.close()
PYEOF
PYRC=$?

# Bring QEMU down. The kernel may already have halted via `exit`; if
# not, kill it.
sleep 1
kill "$QPID" 2>/dev/null || true
wait "$QPID" 2>/dev/null || true
QPID=""

echo "[test_kbd_sigint] --- captured output ---"
cat "$LOG"
echo "[test_kbd_sigint] --- end output ---"

fail=0
if [ "$PYRC" -ne 0 ]; then
    echo "[test_kbd_sigint] MISS: python driver exited rc=$PYRC"
    fail=1
fi

# /bin/yes must have actually launched — its output is "y\n"
# repeated. The kernel timestamps every printk; user-written bytes go
# through verbatim except the kernel mixes its own log lines in. The
# token "yes" appearing as a hamsh prompt echo proves the COMMAND was
# typed; for proof of /bin/yes actually RUNNING we look for the
# repeated single-`y` line that yes itself writes — at least a couple.
if [ "$(grep -c "^y$" "$LOG" 2>/dev/null || true)" -ge 2 ]; then
    echo "[test_kbd_sigint] OK: /bin/yes started and wrote output"
elif grep -E -q "y\s*$" "$LOG" && grep -E -q "/bin/yes" "$LOG"; then
    # Looser fallback: the kernel timestamp framing varies; if we see
    # /bin/yes on the command line AND any line ending in 'y' it ran.
    echo "[test_kbd_sigint] OK: /bin/yes started (loose match)"
else
    echo "[test_kbd_sigint] MISS: /bin/yes never produced output"
    fail=1
fi

# THE assertion: the foreground child exited with code 130. This can
# only happen if the PS/2 Ctrl-C path called
# signal_post_to_foreground(SIGINT). Without the fix the child runs
# forever and no exit notice is ever emitted — this line will be
# absent.
if grep -E -q "task: pid [0-9]+ exited \(code=130\)" "$LOG"; then
    echo "[test_kbd_sigint] OK: foreground child killed by SIGINT (code=130)"
else
    echo "[test_kbd_sigint] MISS: no foreground exit with code 130"
    echo "[test_kbd_sigint]   (PS/2 Ctrl-C did NOT deliver SIGINT)"
    fail=1
fi

# hamsh (pid 1) must survive the Ctrl-C. signal_post_to_foreground
# filters pid 1, so it shouldn't have died — `exit` after our Ctrl-C
# returns code 0. Pid-1 exiting with 130 would mean SIGINT leaked
# onto the shell.
if grep -E -q "task: pid 1 exited \(code=0\)" "$LOG"; then
    echo "[test_kbd_sigint] OK: hamsh survived Ctrl-C and exited cleanly via 'exit'"
elif grep -E -q "task: pid 1 exited \(code=130\)" "$LOG"; then
    echo "[test_kbd_sigint] MISS: hamsh was killed by SIGINT (filter is broken)"
    fail=1
else
    echo "[test_kbd_sigint] MISS: hamsh did not exit cleanly via 'exit'"
    fail=1
fi

# No kernel trap during any of this. The atkbd IRQ path now calls
# into signal_post_to_foreground from interrupt context — make sure
# that doesn't deref anything bad.
if grep -E -q "TRAP: vector|PANIC|panic:" "$LOG"; then
    echo "[test_kbd_sigint] MISS: kernel trap / panic in log"
    fail=1
else
    echo "[test_kbd_sigint] OK: no kernel trap / panic"
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_kbd_sigint] FAIL"
    exit 1
fi
echo "[test_kbd_sigint] PASS"
