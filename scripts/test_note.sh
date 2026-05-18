#!/usr/bin/env bash
# scripts/test_note.sh — regression for SYS_NOTIFY (270) + SYS_NOTED
# (271) and the /proc/<pid>/note write path. Phase C / M16.109.
#
# Same boot pipeline as scripts/test_devproc.sh:
#   1. Build all userland + L-track modules.
#   2. Build tests/test_note.ad -> build/user/test_note.elf
#      (auto-glob in scripts/build_initramfs.py lands it at
#       /bin/test_note inside the cpio archive).
#   3. Plant /init = hamsh so the boot lands at a shell prompt.
#   4. Rebuild the kernel image (picks up the new sysnote.ad +
#      devproc.ad note-kind dispatch + syscall.ad 270/271 wiring).
#   5. Boot QEMU, run `/bin/test_note` via hamsh, then ping the shell
#      with `echo POST_NOTE_OK` to confirm the kernel survived the
#      mid-syscall RIP redirect + noted-return dance.
#
# PASS criteria match what tests/test_note.ad emits:
#   - "[note] start"
#   - "[note] notify_ok"
#   - "[note] handler"          (printed FROM INSIDE the handler)
#   - "[note] back_in_main"
#   - "[note] PASS"
#   - POST_NOTE_OK              (hamsh responsive after the fixture exits)

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-vmlinux.elf
HAMSH_ELF=build/user/hamsh.elf
TEST_ELF=build/user/test_note.elf

echo "[test_note] (1/5) Build userland (hamsh + coreutils)"
bash scripts/build_user.sh >/dev/null
bash scripts/build_modules.sh >/dev/null

echo "[test_note] (2/5) Build tests/test_note.ad -> $TEST_ELF"
python3 -m compiler.adder compile \
    --target=x86_64-adder-user \
    tests/test_note.ad \
    -o "$TEST_ELF" >/dev/null

echo "[test_note] (3/5) Plant /init = hamsh + /bin/test_note in cpio"
INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py >/dev/null

echo "[test_note] (4/5) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

echo "[test_note] (5/5) Boot QEMU + drive the test via hamsh"
LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null' EXIT

set +e
(
    sleep 4
    printf '/bin/test_note\n'
    sleep 4
    printf 'echo POST_NOTE_OK\n'
    sleep 2
    printf 'exit\n'
    sleep 1
) | timeout 25s qemu-system-x86_64 \
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

echo "[test_note] --- captured output ---"
cat "$LOG"
echo "[test_note] --- end output ---"

fail=0
if grep -F -q "[note] start" "$LOG"; then
    echo "[test_note] OK: fixture ran"
else
    echo "[test_note] MISS: fixture banner missing"
    fail=1
fi

if grep -F -q "[note] notify_ok" "$LOG"; then
    echo "[test_note] OK: SYS_NOTIFY installed handler"
else
    echo "[test_note] MISS: SYS_NOTIFY did not return 0"
    fail=1
fi

# This is the LOAD-BEARING assertion: the handler line is printed
# from inside the redirected user-mode frame. Without notify+devproc-
# write+noted all working together it cannot appear.
if grep -F -q "[note] handler" "$LOG"; then
    echo "[test_note] OK: handler ran (RIP redirect succeeded)"
else
    echo "[test_note] MISS: handler did NOT run"
    fail=1
fi

if grep -F -q "[note] back_in_main" "$LOG"; then
    echo "[test_note] OK: SYS_NOTED returned to writer"
else
    echo "[test_note] MISS: did not return to main after handler"
    fail=1
fi

if grep -F -q "[note] PASS" "$LOG"; then
    echo "[test_note] OK: fixture reached PASS marker"
else
    echo "[test_note] MISS: fixture did not reach PASS"
    fail=1
fi

if grep -F -q "POST_NOTE_OK" "$LOG"; then
    echo "[test_note] OK: hamsh remains responsive"
else
    echo "[test_note] MISS: hamsh died after note round-trip"
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_note] FAIL (qemu rc=$rc)"
    exit 1
fi

echo "[test_note] PASS"
