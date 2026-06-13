#!/usr/bin/env bash
# scripts/test_proc_dev_bind.sh - /proc -> /dev namespace-bind gate.
#
# Phase D follow-up: the Layer-2 _u_translate_proc_to_dev string-rewrite
# in linux_abi/u_syscalls.ad was retired in favour of per-leaf FILE
# bindings planted by pgrp_init (sys/src/9/port/chan.ad). This test
# proves the bindings actually route /proc/<name> through #c/<name>
# (== /dev/<name>) by reading both paths from a NATIVE Adder ELF
# (no Layer-2 shim in front of SYS_OPEN) and asserting byte-equality.
# Also asserts /proc/self/<leaf> still works via devproc's `self/`
# inline resolution (not the retired rewrite).

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf
TEST_ELF=build/user/test_proc_dev_bind.elf

echo "[test_proc_dev_bind] (1/5) Build userland (hamsh + coreutils)"
bash scripts/build_user.sh >/dev/null
bash scripts/build_modules.sh >/dev/null

echo "[test_proc_dev_bind] (2/5) Build tests/test_proc_dev_bind.ad -> $TEST_ELF"
python3 -m compiler.adder compile \
    --target=x86_64-adder-user \
    tests/test_proc_dev_bind.ad \
    -o "$TEST_ELF" >/dev/null

echo "[test_proc_dev_bind] (3/5) Plant /init = hamsh + /bin/test_proc_dev_bind in cpio"
INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py >/dev/null

echo "[test_proc_dev_bind] (4/5) Rebuild kernel image"
mkdir -p build
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

echo "[test_proc_dev_bind] (5/5) Boot QEMU + drive the fixture via hamsh"
LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null' EXIT

set +e
(
    # Marker-gated feeder per memory/feedback_interactive_test_wait_for_prompt.md
    # and memory/feedback_serial_test_first_cmd_dropped.md: wait for the
    # shell-ready marker, then RE-SEND until the command's echo lands.
    for _ in $(seq 1 40); do
        grep -q "loop-enter" "$LOG" 2>/dev/null && break
        sleep 0.5
    done
    sleep 1
    printf '/bin/test_proc_dev_bind\n'
    for _ in $(seq 1 10); do
        sleep 1.5
        grep -q "procdevbind" "$LOG" 2>/dev/null && break
        printf '/bin/test_proc_dev_bind\n'
    done
    for _ in $(seq 1 40); do
        grep -Eq '\[procdevbind\] (PASS|FAIL)' "$LOG" 2>/dev/null && break
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

echo "[test_proc_dev_bind] --- captured output ---"
cat "$LOG"
echo "[test_proc_dev_bind] --- end output ---"

fail=0

check() {
    local marker="$1" label="$2"
    if grep -a -F -q "$marker" "$LOG"; then
        echo "[test_proc_dev_bind] OK: $label"
    else
        echo "[test_proc_dev_bind] MISS: $label ($marker)"
        fail=1
    fi
}

check "[procdevbind] start" \
      "fixture ran"
check "[procdevbind] A cpuinfo bind ok" \
      "A: /proc/cpuinfo == /dev/cpuinfo via namespace bind"
check "[procdevbind] B loadavg bind ok" \
      "B: /proc/loadavg == /dev/loadavg via namespace bind"
check "[procdevbind] C hostname bind ok" \
      "C: /proc/hostname == /dev/hostname via namespace bind"
check "[procdevbind] D self-stat ok" \
      "D: /proc/self/stat still resolves via devproc (no rewrite needed)"
check "[procdevbind] PASS" \
      "fixture reached PASS"

if grep -a -F -q "[procdevbind] FAIL" "$LOG"; then
    echo "[test_proc_dev_bind] MISS: fixture FAIL line present:"
    grep -a -F "[procdevbind] FAIL" "$LOG" | sed 's/^/  /'
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_proc_dev_bind] FAIL (qemu rc=$rc)"
    exit 1
fi

echo "[test_proc_dev_bind] PASS — /proc -> #c bindings verified end-to-end"
