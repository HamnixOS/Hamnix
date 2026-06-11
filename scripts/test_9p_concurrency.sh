#!/usr/bin/env bash
# scripts/test_9p_concurrency.sh — V6 tagged 9P concurrency gate.
#
# Proves the kernel 9P client really multiplexes: TWO userland tasks
# (the fixture parent + a spawned reader child) loop open/read/close
# against the SAME mounted distrofs at the same time. The V6 RPC pool
# in sys/src/9/port/9p_client.ad must allocate distinct tags, keep >=2
# T-msgs outstanding, and tag-demux the R-msgs back to the right
# parked waiters.
#
# THE PROOF is kernel-measured: 9p_client.ad tracks the high-water
# mark of simultaneously SENT (in-flight, unanswered) T-messages and
# surfaces it as the read-only file /dev/9pmax. After both loops the
# fixture reads it back IN-GUEST and prints
#
#     [9pconc] inflight_max=N
#
# and FAILs itself when N < 2. The script re-asserts N >= 2 from the
# captured line. (The kernel also printk's a one-shot
# "[9p] tagged concurrency: N T-msgs in flight" when the threshold is
# first crossed — but it is INFO-level and fires while the fixture
# runs from the INTERACTIVE shell, after console_set_interactive()
# gates INFO printk to the ring buffer only, so it never reaches the
# captured serial console; the /dev/9pmax read-back is gate-proof.)
# A client that secretly serializes (old single-outstanding behaviour)
# would still pass every fixture I/O assertion — but read back 1 here,
# and this test FAILs.
#
# Pipeline (same shape as scripts/test_9p_realfd.sh):
#   1. Build userland (hamsh + coreutils + distrofs).
#   2. Build tests/test_9p_concurrency.ad -> build/user/test_9p_concurrency.elf.
#   3. Plant /init = hamsh.elf (fixture lands at /bin/test_9p_concurrency).
#   4. Rebuild the kernel image.
#   5. Boot QEMU, drive `/bin/test_9p_concurrency` via serial stdio.
#   6. Grep the serial log for the [9pconc] markers + the kernel
#      "[9p] tagged concurrency" one-shot.

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf
TEST_ELF=build/user/test_9p_concurrency.elf

echo "[test_9p_concurrency] (1/5) Build userland (hamsh + coreutils + distrofs)"
bash scripts/build_user.sh >/dev/null
bash scripts/build_modules.sh >/dev/null

echo "[test_9p_concurrency] (2/5) Build tests/test_9p_concurrency.ad -> $TEST_ELF"
mkdir -p build/user
python3 -m compiler.adder compile \
    --target=x86_64-adder-user \
    tests/test_9p_concurrency.ad \
    -o "$TEST_ELF" >/dev/null

echo "[test_9p_concurrency] (3/5) Plant /init = hamsh + /bin/test_9p_concurrency in cpio"
INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py >/dev/null

echo "[test_9p_concurrency] (4/5) Rebuild kernel image"
mkdir -p build
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

echo "[test_9p_concurrency] (5/5) Boot QEMU + drive the test via hamsh"
LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null' EXIT

set +e
# Marker-gated feeder: a freshly-booted hamsh sometimes drops the FIRST
# serial command line (it never echoes). Gate on the shell-ready marker,
# then RE-SEND the command until its echo shows up in the log — keyed on
# the echo (immediate on receipt), NOT the fixture marker, so a slow but
# received run is never double-driven.
(
    for _ in $(seq 1 40); do
        grep -q "loop-enter" "$LOG" 2>/dev/null && break
        sleep 0.5
    done
    sleep 1
    printf '/bin/test_9p_concurrency\n'
    for _ in $(seq 1 10); do
        sleep 1.5
        grep -q "bin/test_9p_concurrency" "$LOG" 2>/dev/null && break
        printf '/bin/test_9p_concurrency\n'
    done
    # Wait for the fixture to finish (PASS or any FAIL line), then exit.
    for _ in $(seq 1 60); do
        grep -Eq "\[9pconc\] (PASS|FAIL)" "$LOG" 2>/dev/null && break
        sleep 0.5
    done
    sleep 1
    printf 'exit\n'
    sleep 1
) | timeout 90s qemu-system-x86_64 \
    -kernel "$ELF" \
    -smp 2 \
    -nographic \
    -no-reboot \
    -m 256M \
    -monitor none \
    -serial stdio \
    > "$LOG" 2>&1
rc=$?
set -e

echo "[test_9p_concurrency] --- captured output ---"
cat "$LOG"
echo "[test_9p_concurrency] --- end output ---"

fail=0

check_marker() {
    local marker="$1"
    local label="$2"
    if grep -F -q "$marker" "$LOG"; then
        echo "[test_9p_concurrency] OK: $label"
    else
        echo "[test_9p_concurrency] MISS: $label ($marker)"
        fail=1
    fi
}

# Any per-assertion FAIL line means a round-trip broke somewhere.
if grep -F -q "[9pconc] FAIL:" "$LOG"; then
    echo "[test_9p_concurrency] MISS: per-assertion FAIL line(s) present:"
    grep -F "[9pconc] FAIL:" "$LOG" | sed 's/^/  /'
    fail=1
else
    echo "[test_9p_concurrency] OK: no per-assertion FAIL lines"
fi

check_marker "[9pconc] start"            "fixture ran"
check_marker "[9pconc] mount OK"         "sys_mount completed Tversion+Tattach"
check_marker "[9pconc] seed OK"          "shared file created + written"
check_marker "[9pconc] reader spawned"   "second reader task spawned"
check_marker "[9pconc] reader ready"     "handshake file visible through the mount"
check_marker "[9pconc] reader done"      "child read loop completed clean"
check_marker "[9pconc] parent loop done" "parent read loop completed clean"
check_marker "[9pconc] PASS"             "fixture reached PASS"

# THE point of this gate: the kernel must have had >=2 T-msgs in
# flight at least once. The fixture reads the kernel's high-water mark
# back from /dev/9pmax and prints it; re-assert the value here.
mxline=$(grep -F "[9pconc] inflight_max=" "$LOG" | head -1 || true)
mxval=$(printf '%s\n' "$mxline" | sed -n 's/.*inflight_max=\([0-9][0-9]*\).*/\1/p')
if [ -n "$mxval" ] && [ "$mxval" -ge 2 ]; then
    echo "[test_9p_concurrency] OK: kernel saw >=2 outstanding T-msgs (inflight_max=$mxval)"
else
    echo "[test_9p_concurrency] MISS: kernel saw >=2 outstanding T-msgs (inflight_max='${mxval:-absent}')"
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_9p_concurrency] FAIL (qemu rc=$rc)"
    exit 1
fi

echo "[test_9p_concurrency] PASS"
