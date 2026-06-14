#!/usr/bin/env bash
# scripts/test_hostowner_reach.sh — arch audit §3.2 acceptance gate.
#
# Proves the 5 kernel-internal uid==1 checks in arch/x86/kernel/syscall.ad
# (SYS_SETUID, SYS_USERADD_ROOT, SYS_SVC_PUBLISH, SYS_SET_REALTIME,
# SYS_REBOOT) now route through the single named helper
# `_syscall_require_hostowner` — uniform "<op>: hostowner-required
# (uid=NNNN)" reason in errstr, single source of policy that a future
# Plan-9 reshape can move in one place.
#
# Mirrors scripts/test_default_uid.sh: build hamsh + the test ELF,
# plant /init = hamsh in the cpio, rebuild the kernel image, boot
# QEMU, drive the test via hamsh, grep the serial log.

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf
TEST_ELF=build/user/test_hostowner_reach.elf

echo "[test_hostowner_reach] (1/5) Build userland (hamsh + coreutils)"
bash scripts/build_user.sh >/dev/null
bash scripts/build_modules.sh >/dev/null

echo "[test_hostowner_reach] (2/5) Build tests/test_hostowner_reach.ad -> $TEST_ELF"
python3 -m compiler.adder compile \
    --target=x86_64-adder-user \
    tests/test_hostowner_reach.ad \
    -o "$TEST_ELF" >/dev/null

echo "[test_hostowner_reach] (3/5) Plant /init = hamsh + /bin/test_hostowner_reach in cpio"
INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py >/dev/null

echo "[test_hostowner_reach] (4/5) Rebuild kernel image"
mkdir -p build
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

echo "[test_hostowner_reach] (5/5) Boot QEMU + drive the test via hamsh"
LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null' EXIT

set +e
(
    # Marker-gated feeder (same shape as test_default_uid.sh): wait
    # for the shell-ready marker, then RE-SEND until echo lands so a
    # slow boot isn't double-driven.
    for _ in $(seq 1 40); do
        grep -q "loop-enter" "$LOG" 2>/dev/null && break
        sleep 0.5
    done
    sleep 1
    printf '/bin/test_hostowner_reach\n'
    for _ in $(seq 1 10); do
        sleep 1.5
        grep -q "bin/test_hostowner_reach" "$LOG" 2>/dev/null && break
        printf '/bin/test_hostowner_reach\n'
    done
    for _ in $(seq 1 40); do
        grep -Eq '\[hostowner_reach\] (PASS|FAIL)' "$LOG" 2>/dev/null && break
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

echo "[test_hostowner_reach] --- captured output ---"
cat "$LOG"
echo "[test_hostowner_reach] --- end output ---"

fail=0

check() {
    local marker="$1" label="$2"
    if grep -a -F -q "$marker" "$LOG"; then
        echo "[test_hostowner_reach] OK: $label"
    else
        echo "[test_hostowner_reach] MISS: $label ($marker)"
        fail=1
    fi
}

check "[hostowner_reach] start" \
      "fixture ran"
check "[hostowner_reach] inherited hostowner (uid 1)" \
      "PID 1 inheritance reaches spawned fixture"
check "[hostowner_reach] downgraded to NOBODY (65534)" \
      "SYS_SETUID downgrade observable"

# Each of the 5 ops must surface "hostowner-required (uid=65534)" via
# errstr. The fixture itself does the substring check + logs op=...
# rc=... errstr="..." per call.
for op in setuid useradd svc_publish set_realtime reboot; do
    check "op=$op " \
          "$op exercised as NOBODY"
done

# The "hostowner-required (uid=65534)" shape is the proof the new
# named helper fired; pre-cleanup each arm wrote a unique
# "permission denied (not hostowner)" line, so the new uniform shape
# is a different log substring.
if ! grep -a -F -q "hostowner-required (uid=65534)" "$LOG"; then
    echo "[test_hostowner_reach] MISS: uniform 'hostowner-required (uid=65534)' shape"
    fail=1
else
    echo "[test_hostowner_reach] OK: uniform 'hostowner-required (uid=65534)' shape via _syscall_require_hostowner"
fi

check "[hostowner_reach] PASS" \
      "fixture reached PASS"

if grep -a -F -q "[hostowner_reach] FAIL" "$LOG"; then
    echo "[test_hostowner_reach] MISS: fixture FAIL line present:"
    grep -a -F "[hostowner_reach] FAIL" "$LOG" | sed 's/^/  /'
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_hostowner_reach] FAIL (qemu rc=$rc)"
    exit 1
fi

echo "[test_hostowner_reach] PASS — arch audit §3.2 hostowner-reach cleanup verified: 5 kernel-internal uid==1 checks now route through _syscall_require_hostowner"
