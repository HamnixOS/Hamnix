#!/usr/bin/env bash
# scripts/test_p9file.sh - Phase C / M16.101 regression for the Plan 9
# file-operations cluster: create (260), stat (261), fstat (262),
# remove (263), fd2path (264). Replaces the Phase B -ENOSYS stubs with
# real bodies living in sys/src/9/port/sysfile.ad.
#
# Pipeline:
#   1. Build all userland binaries (hamsh + test_p9file live there).
#   2. Build the test fixture tests/test_p9file.ad to
#      build/user/test_p9file.elf (lands at /bin/test_p9file in the
#      cpio initramfs via build_initramfs.py's auto-glob).
#   3. Make /init = hamsh.elf so we land at a shell prompt.
#   4. Rebuild the kernel image so the new SYS_CREATE/STAT/FSTAT/
#      REMOVE/FD2PATH bodies are compiled in.
#   5. Boot in QEMU, drive `/bin/test_p9file` over the serial stdio,
#      then `exit`.
#   6. Grep the serial log for one marker per primitive plus PASS.
#
# The fixture exercises each primitive against a backend that does
# support it today: stat / fstat / fd2path against the cpio-backed
# /etc/motd, create + remove against tmpfs (/tmp/p9). DMDIR create
# and pipe / socket fd2path return -1 with errstr; the fixture
# doesn't exercise those gaps (they're documented in TODO.md).

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-vmlinux.elf
HAMSH_ELF=build/user/hamsh.elf
TEST_ELF=build/user/test_p9file.elf

echo "[test_p9file] (1/5) Build userland (hamsh + coreutils)"
bash scripts/build_user.sh >/dev/null
bash scripts/build_modules.sh >/dev/null

echo "[test_p9file] (2/5) Build tests/test_p9file.ad -> $TEST_ELF"
python3 -m compiler.adder compile \
    --target=x86_64-adder-user \
    tests/test_p9file.ad \
    -o "$TEST_ELF" >/dev/null

echo "[test_p9file] (3/5) Plant /init = hamsh + /bin/test_p9file in cpio"
INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py >/dev/null

echo "[test_p9file] (4/5) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

echo "[test_p9file] (5/5) Boot QEMU + drive the test via hamsh"
LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null' EXIT

set +e
(
    # Let the kernel finish its smoke tests before hamsh starts
    # SYS_READ'ing stdin. Same pacing as scripts/test_rfork.sh.
    sleep 3
    printf '/bin/test_p9file\n'
    sleep 3
    printf 'exit\n'
    sleep 1
) | timeout 20s qemu-system-x86_64 \
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

echo "[test_p9file] --- captured output ---"
cat "$LOG"
echo "[test_p9file] --- end output ---"

fail=0

# Banner first — proves the fixture ran end to end.
if grep -F -q "[p9file] start" "$LOG"; then
    echo "[test_p9file] OK: fixture ran"
else
    echo "[test_p9file] MISS: fixture banner missing"
    fail=1
fi

# stat /etc/motd — cpio-backed, must serialise a real Dir record.
if grep -F -q "[p9file] stat /etc/motd ok" "$LOG"; then
    echo "[test_p9file] OK: SYS_STAT_P9 (261) returned a Dir record"
else
    echo "[test_p9file] MISS: stat failed"
    fail=1
fi

# fstat on an open /etc/motd fd.
if grep -F -q "[p9file] fstat fd ok" "$LOG"; then
    echo "[test_p9file] OK: SYS_FSTAT_P9 (262) returned a Dir record"
else
    echo "[test_p9file] MISS: fstat failed"
    fail=1
fi

# fd2path — best-effort, must return a non-empty path.
if grep -F -q "[p9file] fd2path ok: " "$LOG"; then
    echo "[test_p9file] OK: SYS_FD2PATH (264) returned a path"
else
    echo "[test_p9file] MISS: fd2path failed"
    fail=1
fi

# create /tmp/p9 — tmpfs-backed, must return a valid fd.
if grep -F -q "[p9file] create /tmp/p9 ok" "$LOG"; then
    echo "[test_p9file] OK: SYS_CREATE (260) returned a tmpfs fd"
else
    echo "[test_p9file] MISS: create failed"
    fail=1
fi

# remove /tmp/p9 — wraps vfs_unlink.
if grep -F -q "[p9file] remove /tmp/p9 ok" "$LOG"; then
    echo "[test_p9file] OK: SYS_REMOVE (263) unlinked tmpfs file"
else
    echo "[test_p9file] MISS: remove failed"
    fail=1
fi

# Aggregate PASS line — proves all five primitives green.
if grep -F -q "[p9file] PASS" "$LOG"; then
    echo "[test_p9file] OK: fixture reached PASS"
else
    echo "[test_p9file] MISS: PASS line absent"
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_p9file] FAIL (qemu rc=$rc)"
    exit 1
fi

echo "[test_p9file] PASS"
