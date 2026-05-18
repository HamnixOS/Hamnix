#!/usr/bin/env bash
# scripts/test_devsysmore.sh — regression for /dev/stat + /dev/mounts +
# /dev/diskstats (M16.135). Combined fixture (tests/test_devsys.ad)
# exercises all three cdevs in a single QEMU boot so we pay one build
# + boot cost for the trio.
#
# Pipeline mirrors test_devsysinfo.sh / test_devstat.sh / test_devid.sh
# exactly:
#   1. Build userland (hamsh, coreutils).
#   2. Build the test fixture tests/test_devsys.ad. build_initramfs.py
#      auto-globs build/user/*.elf so it lands at /bin/test_devsys in
#      the cpio.
#   3. Plant hamsh as /init.
#   4. Rebuild the kernel image so devstat.ad + devmounts.ad +
#      devdiskstats.ad + their FD_*_MARK arms are compiled in.
#   5. Boot in QEMU, drive the fixture over serial stdio, grep the
#      captured log for the contract markers.
#
# PASS markers (each emitted by the fixture on success):
#   - "[devstat] ok"        — /dev/stat blob shape + "cpu" + "btime"
#                              tokens + >=5 lines.
#   - "[devmounts] ok"      — /dev/mounts blob contains "rootfs" row +
#                              >=1 line.
#   - "[devdiskstats] ok"   — /dev/diskstats blob non-empty + >=1 line.
# We also assert the fixture's "done" banner and that hamsh remains
# responsive after the round-trip.

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-vmlinux.elf
HAMSH_ELF=build/user/hamsh.elf
SYS_ELF=build/user/test_devsys.elf

echo "[test_devsysmore] (1/5) Build userland (hamsh + coreutils)"
bash scripts/build_user.sh >/dev/null
bash scripts/build_modules.sh >/dev/null

echo "[test_devsysmore] (2/5) Build tests/test_devsys.ad"
python3 -m compiler.adder compile \
    --target=x86_64-adder-user \
    tests/test_devsys.ad \
    -o "$SYS_ELF" >/dev/null

echo "[test_devsysmore] (3/5) Plant /init = hamsh + /bin/test_devsys in cpio"
INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py >/dev/null

echo "[test_devsysmore] (4/5) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

echo "[test_devsysmore] (5/5) Boot QEMU + drive fixture via hamsh"
LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null' EXIT

set +e
(
    sleep 3
    printf '/bin/test_devsys\n'
    sleep 2
    printf 'echo POST_DEVSYSMORE_OK\n'
    sleep 1
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

echo "[test_devsysmore] --- captured output ---"
cat "$LOG"
echo "[test_devsysmore] --- end output ---"

fail=0

# ---- fixture sanity ----
if grep -F -q "[test_devsys] start" "$LOG"; then
    echo "[test_devsysmore] OK: fixture ran"
else
    echo "[test_devsysmore] MISS: fixture banner missing"
    fail=1
fi

# ---- /dev/stat ----
if grep -F -q "[devstat] ok" "$LOG"; then
    echo "[devstat] ok"
else
    echo "[test_devsysmore] MISS: [devstat] ok marker absent"
    fail=1
fi

# ---- /dev/mounts ----
if grep -F -q "[devmounts] ok" "$LOG"; then
    echo "[devmounts] ok"
else
    echo "[test_devsysmore] MISS: [devmounts] ok marker absent"
    fail=1
fi

# ---- /dev/diskstats ----
if grep -F -q "[devdiskstats] ok" "$LOG"; then
    echo "[devdiskstats] ok"
else
    echo "[test_devsysmore] MISS: [devdiskstats] ok marker absent"
    fail=1
fi

# ---- fixture completion + hamsh responsiveness ----
if grep -F -q "[test_devsys] done" "$LOG"; then
    echo "[test_devsysmore] OK: fixture completed"
else
    echo "[test_devsysmore] MISS: fixture didn't reach done"
    fail=1
fi
if grep -F -q "POST_DEVSYSMORE_OK" "$LOG"; then
    echo "[test_devsysmore] OK: hamsh remains responsive"
else
    echo "[test_devsysmore] MISS: hamsh died after devsys round-trip"
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_devsysmore] FAIL (qemu rc=$rc)"
    exit 1
fi

echo "[test_devsysmore] PASS"
