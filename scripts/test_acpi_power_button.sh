#!/usr/bin/env bash
# scripts/test_acpi_power_button.sh — ACPI power-button SCI -> clean S5.
#
# Real-hardware bug (the Intel NUC): a short power-button press latches
# PWRBTN_STS (PM1 status bit 8) and asserts a LEVEL-triggered, active-LOW
# SCI on FADT.SCI_INT. Before this fix the kernel had ZERO ACPI SCI /
# fixed-event infrastructure, so nothing cleared that write-1-to-clear
# status bit: the level interrupt re-fired forever (pegging a core, fan
# maxes) and the machine never powered off.
#
# The fix (drivers/acpi/acpi.ad + arch/x86/kernel/power.ad + init/main.ad):
#   * parse the FADT fixed-event block (SCI_INT, SMI_CMD, PM1a/b_EVT_BLK,
#     PM1_EVT_LEN),
#   * enable ACPI mode + arm the PM1 power-button ENABLE bit,
#   * route the SCI GSI through the IOAPIC (level/active-low) to vector
#     0x25 and install a handler that write-1-to-clears PWRBTN_STS (so the
#     level line de-asserts) and drives a clean power_action(POWER_POWEROFF).
#
# This test PROVES the SCI handler fires end-to-end on QEMU:
#   1. Boot to the interactive hamsh prompt (heartbeat marker), arming the
#      power button along the way (we assert the "[acpi] power-button SCI
#      routed" line appears, so the handler is actually wired).
#   2. Inject an ACPI power-button event via the QEMU monitor command
#      `system_powerdown` (QEMU's emulated short power-button press).
#   3. PASS iff the guest powers off ON ITS OWN: QEMU exits cleanly (rc != 124)
#      AND the serial log shows the SCI handler's
#         "[acpi] power-button SCI: PWRBTN_STS set -> poweroff"
#      followed by the S5 write "[acpi] S5 write PM1a_CNT=...". That chain can
#      ONLY come from the SCI handler -> power_action -> _do_poweroff -> S5.
#   FAIL if QEMU is still running at the deadline (handler never fired) or a
#   fatal trap marker appears.
#
# QEMU vs real-HW note: `system_powerdown` injects the SAME ACPI fixed
# power-button event a physical short-press raises on the NUC (PWRBTN_STS +
# level SCI on SCI_INT=9). QEMU's emulated chipset wires PM1a_EVT_BLK=0x600,
# PM1_EVT_LEN=4 (enable reg @0x602), SCI_INT=9 — exactly the standard path the
# code drives. The metal-pending difference is only the firmware-specific
# SMI_CMD handoff (often already in ACPI mode under UEFI) and the concrete
# port/GSI values, which are read from the real FADT at runtime.

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf

echo "[test_pwrbtn] (1/3) Build (user + modules + initramfs + kernel)"
bash scripts/build_user.sh >/dev/null
bash scripts/build_modules.sh >/dev/null
python3 scripts/build_initramfs.py >/dev/null
python3 -m compiler.adder compile --target=x86_64-bare-metal \
    init/main.ad -o "$ELF" >/dev/null

SERIAL_LOG=$(mktemp /tmp/pwrbtn-serial.XXXXXX.log)
MON_FIFO=$(mktemp -u /tmp/pwrbtn-mon.XXXXXX.fifo)
mkfifo "$MON_FIFO"
trap 'rm -f "$SERIAL_LOG" "$MON_FIFO"' EXIT

echo "[test_pwrbtn] (2/3) Boot QEMU; inject power-button via monitor"

# Hold the monitor FIFO open for the whole run (fd 9) so QEMU's monitor
# doesn't see EOF and exit, and so we can dribble the command in once the
# guest is ready. We open it READ-WRITE (9<>): opening a FIFO write-only
# (9>) BLOCKS until a reader appears, but our reader is QEMU which we
# launch on the NEXT line — a deadlock. Read-write open returns immediately
# and also keeps a reader end alive so QEMU never sees EOF. Serial goes to
# its own file we poll for readiness.
exec 9<>"$MON_FIFO"

set +e
timeout 300s qemu-system-x86_64 \
    -kernel "$ELF" \
    -smp 2 \
    -nographic \
    -no-reboot \
    -m 256M \
    -serial "file:$SERIAL_LOG" \
    -monitor stdio \
    < "$MON_FIFO" > /dev/null 2>&1 &
QEMU_PID=$!

# Wait for the interactive prompt (heartbeat) before injecting the press —
# gate on the marker, not a fixed sleep, so this stays robust if boot slows
# under load. Full integration boot to the first heartbeat takes a while
# under TCG with -smp 2, so the window is generous. Also bail early if QEMU
# dies or a fatal trap shows up.
ready=0
for _ in $(seq 1 280); do
    if grep -qa "\[hamsh-alive\] tick=" "$SERIAL_LOG" 2>/dev/null; then
        ready=1
        break
    fi
    if ! kill -0 "$QEMU_PID" 2>/dev/null; then
        break
    fi
    sleep 1
done

if [ "$ready" -ne 1 ]; then
    echo "[test_pwrbtn] FAIL: guest never reached interactive prompt" >&2
    kill "$QEMU_PID" 2>/dev/null || true
    exec 9>&-
    wait "$QEMU_PID" 2>/dev/null
    echo "[test_pwrbtn] --- serial tail ---"; tail -20 "$SERIAL_LOG" || true
    exit 1
fi

echo "[test_pwrbtn] guest ready — injecting 'system_powerdown' (ACPI press)"
# Inject the emulated short power-button press through the QEMU monitor.
printf 'system_powerdown\n' >&9

# Wait for QEMU to power off on its own (the SCI handler -> S5 chain), or for
# the timeout-wrapped QEMU to be killed.
wait "$QEMU_PID"
rc=$?
exec 9>&-

echo "[test_pwrbtn] (3/3) Assertions (qemu rc=$rc)"
echo "[test_pwrbtn] --- acpi/power markers ---"
grep -aE "\[acpi\]|power-button|SCI fired|S5 write|powering off|SCI override" "$SERIAL_LOG" || true
echo "[test_pwrbtn] --- end ---"

fail=0

# A fatal trap must NOT appear. Anchor on real fatal markers — NOT a bare
# "panic" substring, which benign self-test lines legitimately contain
# (e.g. "[uaccess-smoke] PASS: unmapped address -> EFAULT (no panic)").
if grep -qaiE "Kernel panic:|triple fault|unhandled trap|\bvec=6\b ring3" "$SERIAL_LOG"; then
    echo "[test_pwrbtn] FAIL: fatal trap marker in serial log" >&2
    fail=1
fi

# The power button must have been ARMED + routed during boot (proves wiring).
if grep -qaF "[acpi] power-button SCI routed:" "$SERIAL_LOG"; then
    echo "[test_pwrbtn] OK: power-button SCI was armed + routed at boot"
else
    echo "[test_pwrbtn] FAIL: '[acpi] power-button SCI routed' marker missing" >&2
    fail=1
fi

# The SCI handler must have FIRED in response to the injected press. The
# vector-0x25 handler stamps EMERG markers (so they survive the post-
# interactive console-loglevel gate): "[acpi] SCI fired: PM1_STS=..." on
# entry and "[acpi] power-button SCI: PWRBTN_STS set -> poweroff" when it
# acts. Either proves the hardware SCI reached our do_irq handler.
if grep -qaF "[acpi] power-button SCI: PWRBTN_STS set -> poweroff" "$SERIAL_LOG"; then
    echo "[test_pwrbtn] OK: SCI handler fired (PWRBTN_STS observed + cleared)"
else
    echo "[test_pwrbtn] FAIL: SCI handler never observed PWRBTN_STS" >&2
    fail=1
fi

# The handler must have driven the real S5 write (handler -> power_action).
if grep -qaE '\[acpi\] S5 write PM1a_CNT=0x[0-9A-Fa-f]+' "$SERIAL_LOG"; then
    echo "[test_pwrbtn] OK: SCI handler drove the real S5 PM1a write"
else
    echo "[test_pwrbtn] FAIL: S5 PM1a write marker missing" >&2
    fail=1
fi

# The guest must power off on its own — not a timeout kill.
if [ "$rc" -eq 124 ]; then
    echo "[test_pwrbtn] FAIL: QEMU hung (timeout) — power button did not power off" >&2
    fail=1
else
    echo "[test_pwrbtn] OK: QEMU exited on its own (rc=$rc) — clean power-off"
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_pwrbtn] FAIL"
    exit 1
fi

echo "[acpi] power-button PASS"
exit 0
