#!/usr/bin/env bash
# scripts/test_p9_drift_ctls.sh — F2 #447 acceptance gate.
#
# Drives tests/test_p9_drift_ctls.ad which exercises the four ctl-file
# surfaces that retire drift syscalls (per docs/native-api.md updated
# migration table):
#
#   /proc/self/ctl    `pri <n>`    replaces SYS_NICE (311)
#   /proc/svc/ctl     verb writes  replaces SYS_SVC_CTL (296)
#   /net/dns          server pin   replaces SYS_NETCFG SET_DNS (286 op 3)
#   /dev/wsys/ctl     (covered by the build — fixture restricts to
#                     the non-hostowner cases since it runs as a
#                     non-PID-1 child)
#
# Pipeline matches scripts/test_ns_enoent.sh: build hamsh + the
# test ELF, plant /init=hamsh, rebuild kernel, boot, drive over
# serial stdio with the marker-gated feeder.

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf
TEST_ELF=build/user/test_p9_drift_ctls.elf

echo "[test_p9_drift_ctls] (1/5) Build userland (hamsh + coreutils)"
bash scripts/build_user.sh >/dev/null

echo "[test_p9_drift_ctls] (2/5) Build tests/test_p9_drift_ctls.ad -> $TEST_ELF"
python3 -m compiler.adder compile \
    --target=x86_64-adder-user \
    tests/test_p9_drift_ctls.ad \
    -o "$TEST_ELF" >/dev/null

echo "[test_p9_drift_ctls] (3/5) Plant /init = hamsh + /bin/test_p9_drift_ctls in cpio"
INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py >/dev/null

echo "[test_p9_drift_ctls] (4/5) Rebuild kernel image"
mkdir -p build
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

echo "[test_p9_drift_ctls] (5/5) Boot QEMU + drive the test via hamsh"
LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null' EXIT

set +e
(
    # Marker-gated feeder (same proven shape as test_ns_enoent.sh):
    # gate on the shell-ready marker, then RE-SEND the command until its
    # echo shows up.
    for _ in $(seq 1 40); do
        grep -q "loop-enter" "$LOG" 2>/dev/null && break
        sleep 0.5
    done
    sleep 1
    printf '/bin/test_p9_drift_ctls\n'
    for _ in $(seq 1 10); do
        sleep 1.5
        grep -q "bin/test_p9_drift_ctls" "$LOG" 2>/dev/null && break
        printf '/bin/test_p9_drift_ctls\n'
    done
    # Wait for the fixture to finish (PASS or a FAIL line), then exit.
    for _ in $(seq 1 40); do
        grep -Eq '\[p9drift\] (PASS|FAIL)' "$LOG" 2>/dev/null && break
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

echo "[test_p9_drift_ctls] --- captured output ---"
cat "$LOG"
echo "[test_p9_drift_ctls] --- end output ---"

fail=0

check() {
    local marker="$1" label="$2"
    if grep -a -F -q "$marker" "$LOG"; then
        echo "[test_p9_drift_ctls] OK: $label"
    else
        echo "[test_p9_drift_ctls] MISS: $label ($marker)"
        fail=1
    fi
}

check "[p9drift] start" \
      "fixture ran"
check "[p9drift] /proc/self/ctl pri 5 OK" \
      "/proc/self/ctl pri 5 write applied (sched_set_nice from ctl)"
check "[p9drift] /proc/self/ctl pri -10 OK" \
      "/proc/self/ctl pri -10 write applied (signed parse from ctl)"
check "[p9drift] /proc/svc/ctl start sshd OK (enqueued)" \
      "/proc/svc/ctl write reached svc_ctl_enqueue"
check "[p9drift] /proc/svc/ctl read rejected OK" \
      "/proc/svc/ctl read returns Plan 9 'ctl: not readable'"
check "[p9drift] /net/dns set+get OK" \
      "/net/dns write 'server 1.1.1.1' then read echoes back"
check "[p9drift] PASS" \
      "fixture reached PASS"

if grep -a -F -q "[p9drift] FAIL" "$LOG"; then
    echo "[test_p9_drift_ctls] MISS: fixture FAIL line present:"
    grep -a -F "[p9drift] FAIL" "$LOG" | sed 's/^/  /'
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_p9_drift_ctls] FAIL (qemu rc=$rc)"
    exit 1
fi

echo "[test_p9_drift_ctls] PASS — the four F2 drift-syscall replacement ctl files (pri / svc/ctl / net/dns) work end-to-end through write(/read) on a real fd, not a syscall arm"
