#!/usr/bin/env bash
# scripts/test_phase_d_followups.sh - Phase D follow-ups bundle gate.
#
# Three small Chan / fd polish items landed together because they all
# touch the same fd/Chan surface:
#
#   A. fd2path EXACT post-resolve path -- per-fd opened-path slot in
#      TaskStruct, stamped by vfs_open / vfs_open_write.
#   B. wstat / fwstat field set -- length / mtime / mode / name leg
#      accept non-sentinel values (previously stub-rejected). gid /
#      muid still surface "not supported" deliberately (see
#      sys/src/9/port/sysfile.ad's _apply_wstat comment block).
#   C. /var as a per-Pgrp bind (#t/var) -- the namespace owns /var,
#      the backend router only routes the post-resolve key. No global
#      /var literal-path bypass in the kernel.
#
# Pipeline mirrors scripts/test_default_uid.sh: build hamsh + the
# fixture, plant /init = hamsh in the cpio (so the test runs from a
# realistic shell), rebuild the kernel image, boot QEMU, drive the
# fixture, grep the serial log.

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf
TEST_ELF=build/user/test_phase_d_followups.elf

echo "[test_phase_d_followups] (1/5) Build userland (hamsh + coreutils)"
bash scripts/build_user.sh >/dev/null
bash scripts/build_modules.sh >/dev/null

echo "[test_phase_d_followups] (2/5) Build tests/test_phase_d_followups.ad -> $TEST_ELF"
python3 -m compiler.adder compile \
    --target=x86_64-adder-user \
    tests/test_phase_d_followups.ad \
    -o "$TEST_ELF" >/dev/null

echo "[test_phase_d_followups] (3/5) Plant /init = hamsh + /bin/test_phase_d_followups in cpio"
INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py >/dev/null

echo "[test_phase_d_followups] (4/5) Rebuild kernel image"
mkdir -p build
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

echo "[test_phase_d_followups] (5/5) Boot QEMU + drive the fixture via hamsh"
LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null' EXIT

set +e
(
    # Marker-gated feeder per memory/feedback_interactive_test_wait_for_prompt.md
    # and memory/feedback_serial_test_first_cmd_dropped.md: wait for the
    # shell-ready marker, then RE-SEND until the command's echo lands
    # in the log.
    for _ in $(seq 1 40); do
        grep -q "loop-enter" "$LOG" 2>/dev/null && break
        sleep 0.5
    done
    sleep 1
    printf '/bin/test_phase_d_followups\n'
    for _ in $(seq 1 10); do
        sleep 1.5
        grep -q "phase_d_followups" "$LOG" 2>/dev/null && break
        printf '/bin/test_phase_d_followups\n'
    done
    for _ in $(seq 1 40); do
        grep -Eq '\[phasedfu\] (PASS|FAIL)' "$LOG" 2>/dev/null && break
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

echo "[test_phase_d_followups] --- captured output ---"
cat "$LOG"
echo "[test_phase_d_followups] --- end output ---"

fail=0

check() {
    local marker="$1" label="$2"
    if grep -a -F -q "$marker" "$LOG"; then
        echo "[test_phase_d_followups] OK: $label"
    else
        echo "[test_phase_d_followups] MISS: $label ($marker)"
        fail=1
    fi
}

check "[phasedfu] start" \
      "fixture ran"
check "[phasedfu] A fd2path-exact ok" \
      "A: fd2path returns the post-resolve opened path"
check "[phasedfu] B wstat-mtime ok" \
      "B: wstat accepts a non-sentinel mtime (tmpfs leg, ext4 leg when present)"
check "[phasedfu] C var-per-pgrp ok" \
      "C: /var is reachable as a per-Pgrp bind and fd2path reports it"
check "[phasedfu] PASS" \
      "fixture reached PASS"

if grep -a -F -q "[phasedfu] FAIL" "$LOG"; then
    echo "[test_phase_d_followups] MISS: fixture FAIL line present:"
    grep -a -F "[phasedfu] FAIL" "$LOG" | sed 's/^/  /'
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_phase_d_followups] FAIL (qemu rc=$rc)"
    exit 1
fi

echo "[test_phase_d_followups] PASS — fd2path exact + wstat mtime + /var per-Pgrp all verified"
