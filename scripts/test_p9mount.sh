#!/usr/bin/env bash
# scripts/test_p9mount.sh - Phase C / M16.107 regression for the
# Plan 9 namespace primitives: bind (257), mount (258), unmount (259).
# Replaces the Phase B -ENOSYS stubs with real bodies living in
# sys/src/9/port/syschan.ad + sys/src/9/port/chan.ad (the channel +
# mount-table skeleton).
#
# Pipeline:
#   1. Build all userland binaries (hamsh + test_p9mount).
#   2. Build the test fixture tests/test_p9mount.ad to
#      build/user/test_p9mount.elf (lands at /bin/test_p9mount in
#      the cpio initramfs via build_initramfs.py's auto-glob).
#   3. Make /init = hamsh.elf so we land at a shell prompt.
#   4. Rebuild the kernel image so the new SYS_BIND / SYS_MOUNT /
#      SYS_UNMOUNT bodies are compiled in.
#   5. Boot in QEMU, drive `/bin/test_p9mount` over the serial
#      stdio, then `exit`.
#   6. Grep the serial log for one marker per primitive + the PASS line.
#
# The fixture exercises bind() against the cpio-backed /etc/motd
# path (alias /sysroot/motd → /etc/motd), proves resolve_path
# rewrites the prefix on every open, then unmount()s and proves
# the alias is gone. mount() is exercised separately with a real
# srvfd; the SRV-kind chan is inert for opens at this milestone
# (no 9P client yet — Phase D's hamwd is the consumer) but the
# call shape and bookkeeping are validated.

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf
TEST_ELF=build/user/test_p9mount.elf

echo "[test_p9mount] (1/5) Build userland (hamsh + coreutils)"
bash scripts/build_user.sh >/dev/null
bash scripts/build_modules.sh >/dev/null

echo "[test_p9mount] (2/5) Build tests/test_p9mount.ad -> $TEST_ELF"
python3 -m compiler.adder compile \
    --target=x86_64-adder-user \
    tests/test_p9mount.ad \
    -o "$TEST_ELF" >/dev/null

echo "[test_p9mount] (3/5) Plant /init = hamsh + /bin/test_p9mount in cpio"
INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py >/dev/null

echo "[test_p9mount] (4/5) Rebuild kernel image"
mkdir -p build
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

echo "[test_p9mount] (5/5) Boot QEMU + drive the test via hamsh"
LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null' EXIT

set +e
(
    # Let the kernel finish its smoke tests before hamsh starts
    # SYS_READ'ing stdin. Same pacing as scripts/test_p9file.sh.
    sleep 3
    printf '/bin/test_p9mount\n'
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

echo "[test_p9mount] --- captured output ---"
cat "$LOG"
echo "[test_p9mount] --- end output ---"

fail=0

if grep -F -q "[p9mount] start" "$LOG"; then
    echo "[test_p9mount] OK: fixture ran"
else
    echo "[test_p9mount] MISS: fixture banner missing"
    fail=1
fi

if grep -F -q "[p9mount] bind /sysroot -> /etc ok" "$LOG"; then
    echo "[test_p9mount] OK: SYS_BIND (257) accepted bind"
else
    echo "[test_p9mount] MISS: bind failed"
    fail=1
fi

if grep -F -q "[p9mount] open /sysroot/motd ok fd=" "$LOG"; then
    echo "[test_p9mount] OK: resolve_path rewrote /sysroot -> /etc"
else
    echo "[test_p9mount] MISS: open through bind failed"
    fail=1
fi

if grep -F -q "[p9mount] read /sysroot/motd ok" "$LOG"; then
    echo "[test_p9mount] OK: bound fd reads from underlying file"
else
    echo "[test_p9mount] MISS: read through bind failed"
    fail=1
fi

if grep -F -q "[p9mount] unmount /sysroot ok" "$LOG"; then
    echo "[test_p9mount] OK: SYS_UNMOUNT (259) removed binding"
else
    echo "[test_p9mount] MISS: unmount failed"
    fail=1
fi

if grep -F -q "[p9mount] open /sysroot/motd after unmount fails (expected)" "$LOG"; then
    echo "[test_p9mount] OK: lookup post-unmount falls through to -ENOENT"
else
    echo "[test_p9mount] MISS: alias still resolves after unmount"
    fail=1
fi

if grep -F -q "[p9mount] mount srvfd ok" "$LOG"; then
    echo "[test_p9mount] OK: SYS_MOUNT (258) accepted srvfd"
else
    echo "[test_p9mount] MISS: mount srvfd failed"
    fail=1
fi

if grep -F -q "[p9mount] unmount srv ok" "$LOG"; then
    echo "[test_p9mount] OK: srv unmount cleaned the table"
else
    echo "[test_p9mount] MISS: srv unmount failed"
    fail=1
fi

if grep -F -q "[p9mount] PASS" "$LOG"; then
    echo "[test_p9mount] OK: fixture reached PASS"
else
    echo "[test_p9mount] MISS: PASS line absent"
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_p9mount] FAIL (qemu rc=$rc)"
    exit 1
fi

echo "[test_p9mount] PASS"
