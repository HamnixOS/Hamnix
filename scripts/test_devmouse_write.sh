#!/usr/bin/env bash
# scripts/test_devmouse_write.sh — writable /dev/mouse: synthetic-event
# injection (the Plan 9 writable-/dev/mouse capability + Linux /dev/uinput
# in one).
#
# devmouse_write() in sys/src/9/port/devmouse.ad used to be a stub that
# rejected every writer (return -1). This fixture proves the real
# implementation: a write to /dev/mouse parses an ASCII event line in the
# SAME format devmouse_read emits — "<dx> <dy> <buttons>\n" — packs the
# fields into the int32 ring encoding, and pushes it onto the auxmouse ring
# (drivers/input/auxmouse.ad::mouse_rx_push) so a SUBSEQUENT devmouse_read
# pops it back out. /dev/mouse becomes a loopback injection channel.
#
# Mechanism (pure boot self-test, no userland interaction):
#   1. scripts/build_initramfs.py honours ENABLE_DEVMOUSE_WRITE_TEST=1: it
#      plants /etc/devmouse-write-test (the gate marker).
#   2. init/main.ad at boot:37.dmw detects the marker and runs
#      devmouse_write_selftest() (sys/src/9/port/devmouse.ad): it injects
#      "5 -3 1\n" via devmouse_write, reads it back via devmouse_read,
#      decodes the ASCII line, and asserts dx==5, dy==-3, buttons==1, plus
#      a malformed-input reject path (a non-numeric line must return -1).
#   3. We boot the kernel (the _build_lock.sh qemu shim wraps the 64-bit
#      ELF in a BIOS GRUB ISO automatically — a raw `qemu -kernel` of the
#      higher-half ELF always fails on this host) and grep the serial log
#      for `[DEVMOUSE_WRITE] PASS`.
#
# Default boots ship NO /etc/devmouse-write-test file, so the self-test is
# a no-op skip everywhere else.
#
# Pass marker:  [test_devmouse_write] PASS
# Fail marker:  [test_devmouse_write] FAIL

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf
BOOT_TIMEOUT="${DEVMOUSE_WRITE_BOOT_TIMEOUT:-120}"

echo "[test_devmouse_write] (1/3) Build userland (init)"
bash scripts/build_user.sh >/dev/null

echo "[test_devmouse_write] (2/3) Build kernel with /etc/devmouse-write-test marker"
INIT_ELF=build/user/init.elf ENABLE_DEVMOUSE_WRITE_TEST=1 \
    python3 scripts/build_initramfs.py >/dev/null
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1 || true' EXIT

echo "[test_devmouse_write] (3/3) Boot QEMU and run the devmouse-write self-test"
set +e
timeout "${BOOT_TIMEOUT}s" qemu-system-x86_64 \
    -kernel "$ELF" \
    -smp 1 \
    -nographic \
    -no-reboot \
    -m 256M \
    -monitor none \
    -serial stdio \
    </dev/null > "$LOG" 2>&1
rc=$?
set -e

echo "[test_devmouse_write] --- devmouse-write self-test output ---"
grep -a -E "\[DEVMOUSE_WRITE\]|\[MOUSE_PUMP\]|\[boot:37.dmw\]" "$LOG" || true
echo "[test_devmouse_write] --- end ---"

fail=0

# rc=124 is the expected timeout kill (kernel halts without powering off
# qemu); rc=0 a clean shutdown. Anything else is a real QEMU failure.
if [ "$rc" -ne 0 ] && [ "$rc" -ne 124 ]; then
    echo "[test_devmouse_write] FAIL: qemu exited rc=$rc" >&2
    fail=1
fi

# An explicit internal failure is fatal.
if grep -a -qF "[DEVMOUSE_WRITE] FAIL" "$LOG"; then
    echo "[test_devmouse_write] FAIL: kernel self-test reported an internal failure" >&2
    grep -a -F "[DEVMOUSE_WRITE] FAIL" "$LOG" >&2 || true
    fail=1
fi

if ! grep -a -qF "[DEVMOUSE_WRITE] PASS" "$LOG"; then
    echo "[test_devmouse_write] FAIL: '[DEVMOUSE_WRITE] PASS' not found in serial log." >&2
    fail=1
fi

# LIVE-MOUSE PUMP assertion: the HW-mouse-ring -> mouse_pump_to_compositor
# -> wsys_route path (the previously-DEAD live cursor path) must drain the
# ring. A [MOUSE_PUMP] FAIL is fatal; the PASS marker is required.
if grep -a -qF "[MOUSE_PUMP] FAIL" "$LOG"; then
    echo "[test_devmouse_write] FAIL: mouse-pump self-test reported a failure" >&2
    grep -a -F "[MOUSE_PUMP] FAIL" "$LOG" >&2 || true
    fail=1
fi
if ! grep -a -qF "[MOUSE_PUMP] PASS" "$LOG"; then
    echo "[test_devmouse_write] FAIL: '[MOUSE_PUMP] PASS' not found — the HW mouse-ring pump (live cursor path) is not wired." >&2
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_devmouse_write] FAIL"
    exit 1
fi

echo "[test_devmouse_write] PASS — writable /dev/mouse injects synthetic events through the auxmouse ring"
