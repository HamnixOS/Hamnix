#!/usr/bin/env bash
# scripts/test_devproc.sh — regression for the Plan 9
# /proc/<pid>/<file> device family.
#
# Same pipeline shape as test_devpid.sh / test_devcons.sh:
#   1. Build all userland + L-track modules.
#   2. Build tests/test_devproc.ad -> build/user/test_devproc.elf
#      (auto-glob in scripts/build_initramfs.py lands it at
#       /bin/test_devproc inside the cpio archive).
#   3. Plant /init = hamsh so the boot lands at a shell prompt.
#   4. Rebuild the kernel image (picks up the new sys/src/9/port/
#      devproc.ad + fs/vfs.ad FD_PROC_MARK dispatch).
#   5. Boot QEMU, run `/bin/test_devproc` via hamsh, then ping the
#      shell with `echo POST_PROC_OK` to confirm we didn't take the
#      console down with us.
#
# PASS criteria match what tests/test_devproc.ad emits:
#   - "[test_devproc] start"
#   - "[test_devproc] status=<pid> <name> <state> <pml4>"
#   - "[test_devproc] cwd=/"  (or any non-empty path)
#   - "[test_devproc] bad_open_ok"
#   - "[test_devproc] PASS"
#   - POST_PROC_OK (hamsh responsive after the fixture exits)

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-vmlinux.elf
HAMSH_ELF=build/user/hamsh.elf
TEST_ELF=build/user/test_devproc.elf

echo "[test_devproc] (1/5) Build userland (hamsh + coreutils)"
bash scripts/build_user.sh >/dev/null
bash scripts/build_modules.sh >/dev/null

echo "[test_devproc] (2/5) Build tests/test_devproc.ad -> $TEST_ELF"
python3 -m compiler.adder compile \
    --target=x86_64-adder-user \
    tests/test_devproc.ad \
    -o "$TEST_ELF" >/dev/null

echo "[test_devproc] (3/5) Plant /init = hamsh + /bin/test_devproc in cpio"
INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py >/dev/null

echo "[test_devproc] (4/5) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

echo "[test_devproc] (5/5) Boot QEMU + drive the test via hamsh"
LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null' EXIT

set +e
(
    sleep 3
    printf '/bin/test_devproc\n'
    sleep 2
    printf 'echo POST_PROC_OK\n'
    sleep 1
    printf 'exit\n'
    sleep 1
) | timeout 15s qemu-system-x86_64 \
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

echo "[test_devproc] --- captured output ---"
cat "$LOG"
echo "[test_devproc] --- end output ---"

fail=0
if grep -F -q "[test_devproc] start" "$LOG"; then
    echo "[test_devproc] OK: fixture ran"
else
    echo "[test_devproc] MISS: fixture banner missing"
    fail=1
fi

# Status line must include at least the pid we asked for. We don't
# pin the exact name/state/pml4 — those vary across kernel rebuilds —
# but a leading "1 " token is the minimum the test asserts.
if grep -E -q "\[test_devproc\] status=1 " "$LOG"; then
    echo "[test_devproc] OK: /proc/1/status returned pid-1 row"
else
    echo "[test_devproc] MISS: /proc/1/status row absent / wrong shape"
    fail=1
fi

# CWD is "/" by default for kernel-spawned user tasks. We accept any
# non-empty path that starts with '/' so a future test that changes
# CWD before the fixture runs doesn't have to update this script too.
if grep -E -q "\[test_devproc\] cwd=/" "$LOG"; then
    echo "[test_devproc] OK: /proc/1/cwd returned absolute path"
else
    echo "[test_devproc] MISS: /proc/1/cwd missing or empty"
    fail=1
fi

# §13: real Linux-shape /proc/<pid>/stat. The fixture asserts the
# line opens with "1 (" (field 1 = pid, field 2 = "(comm)").
if grep -E -q "\[test_devproc\] stat=1 \(" "$LOG"; then
    echo "[test_devproc] OK: /proc/1/stat returned Linux-shape line"
else
    echo "[test_devproc] MISS: /proc/1/stat missing / wrong shape"
    fail=1
fi

# §13: /proc/<pid>/cmdline + /proc/<pid>/maps.
if grep -F -q "[test_devproc] cmdline_ok" "$LOG"; then
    echo "[test_devproc] OK: /proc/1/cmdline served"
else
    echo "[test_devproc] MISS: /proc/1/cmdline failed"
    fail=1
fi
if grep -F -q "[test_devproc] maps_ok" "$LOG"; then
    echo "[test_devproc] OK: /proc/1/maps served"
else
    echo "[test_devproc] MISS: /proc/1/maps failed"
    fail=1
fi

if grep -F -q "[test_devproc] bad_open_ok" "$LOG"; then
    echo "[test_devproc] OK: open(/proc/999/status) rejected"
else
    echo "[test_devproc] MISS: /proc/999/status was NOT rejected"
    fail=1
fi

if grep -F -q "[test_devproc] PASS" "$LOG"; then
    echo "[test_devproc] OK: fixture reached PASS marker"
else
    echo "[test_devproc] MISS: fixture did not reach PASS"
    fail=1
fi

if grep -F -q "POST_PROC_OK" "$LOG"; then
    echo "[test_devproc] OK: hamsh remains responsive"
else
    echo "[test_devproc] MISS: hamsh died after /proc round-trip"
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_devproc] FAIL (qemu rc=$rc)"
    exit 1
fi

echo "[test_devproc] PASS"
