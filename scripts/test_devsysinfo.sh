#!/usr/bin/env bash
# scripts/test_devsysinfo.sh — regression for /dev/cpuinfo + /dev/meminfo.
#
# Pipeline mirrors test_devmouse.sh / test_devtime.sh exactly, except
# we run BOTH fixtures (test_devcpuinfo + test_devmeminfo) inside the
# same QEMU boot so we only pay the build-and-boot cost once:
#   1. Build userland (hamsh, coreutils).
#   2. Build the test fixtures tests/test_devcpuinfo.ad and
#      tests/test_devmeminfo.ad. build_initramfs.py auto-globs
#      build/user/*.elf so they land at /bin/test_devcpuinfo and
#      /bin/test_devmeminfo in the cpio.
#   3. Plant hamsh as /init.
#   4. Rebuild the kernel image so devcpuinfo.ad + devmeminfo.ad +
#      FD_CPUINFO_MARK / FD_MEMINFO_MARK arms are compiled in.
#   5. Boot in QEMU, drive both fixtures over the serial stdio, grep
#      the captured log for the contract markers.
#
# PASS markers:
#   - "[devcpuinfo] vendor=GenuineIntel" or "vendor=AuthenticAMD"
#     (the test fixture emits one of these when its scan finds the
#     vendor string in the captured blob — printed without the leading
#     test_devcpuinfo prefix so the contract surface is grep-stable).
#   - "[devmeminfo] MemTotal=<digits> kB" (the fixture emits this
#     after validating the digit run + " kB" suffix).
# We also assert each fixture's "done" banner and that hamsh remains
# responsive after both round-trips.

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf
CPU_ELF=build/user/test_devcpuinfo.elf
MEM_ELF=build/user/test_devmeminfo.elf

echo "[test_devsysinfo] (1/5) Build userland (hamsh + coreutils)"
bash scripts/build_user.sh >/dev/null
bash scripts/build_modules.sh >/dev/null

echo "[test_devsysinfo] (2/5) Build tests/test_devcpuinfo.ad + test_devmeminfo.ad"
python3 -m compiler.adder compile \
    --target=x86_64-adder-user \
    tests/test_devcpuinfo.ad \
    -o "$CPU_ELF" >/dev/null
python3 -m compiler.adder compile \
    --target=x86_64-adder-user \
    tests/test_devmeminfo.ad \
    -o "$MEM_ELF" >/dev/null

echo "[test_devsysinfo] (3/5) Plant /init = hamsh + /bin/test_dev{cpuinfo,meminfo} in cpio"
INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py >/dev/null

echo "[test_devsysinfo] (4/5) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

echo "[test_devsysinfo] (5/5) Boot QEMU + drive both fixtures via hamsh"
LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null' EXIT

set +e
(
    sleep 3
    printf '/bin/test_devcpuinfo\n'
    sleep 2
    printf '/bin/test_devmeminfo\n'
    sleep 2
    printf 'echo POST_SYSINFO_OK\n'
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

echo "[test_devsysinfo] --- captured output ---"
cat "$LOG"
echo "[test_devsysinfo] --- end output ---"

fail=0

# ---- /dev/cpuinfo asserts ----
if grep -F -q "[test_devcpuinfo] start" "$LOG"; then
    echo "[test_devsysinfo] OK: cpuinfo fixture ran"
else
    echo "[test_devsysinfo] MISS: cpuinfo fixture banner missing"
    fail=1
fi
if grep -F -q "[test_devcpuinfo] opened /dev/cpuinfo OK" "$LOG"; then
    echo "[test_devsysinfo] OK: /dev/cpuinfo opened cleanly"
else
    echo "[test_devsysinfo] MISS: /dev/cpuinfo open failed"
    fail=1
fi
if grep -E -q "\[test_devcpuinfo\] vendor=(GenuineIntel|AuthenticAMD)" "$LOG"; then
    echo "[devcpuinfo] vendor=$(grep -E -o 'vendor=(GenuineIntel|AuthenticAMD)' "$LOG" | head -n1 | cut -d= -f2)"
else
    echo "[test_devsysinfo] MISS: vendor= line absent or unrecognised"
    fail=1
fi
if grep -F -q "[test_devcpuinfo] done" "$LOG"; then
    echo "[test_devsysinfo] OK: cpuinfo fixture completed"
else
    echo "[test_devsysinfo] MISS: cpuinfo fixture didn't reach done"
    fail=1
fi

# ---- /dev/meminfo asserts ----
if grep -F -q "[test_devmeminfo] start" "$LOG"; then
    echo "[test_devsysinfo] OK: meminfo fixture ran"
else
    echo "[test_devsysinfo] MISS: meminfo fixture banner missing"
    fail=1
fi
if grep -F -q "[test_devmeminfo] opened /dev/meminfo OK" "$LOG"; then
    echo "[test_devsysinfo] OK: /dev/meminfo opened cleanly"
else
    echo "[test_devsysinfo] MISS: /dev/meminfo open failed"
    fail=1
fi
if grep -E -q "\[test_devmeminfo\] MemTotal=[0-9]+ kB" "$LOG"; then
    mt=$(grep -E -o 'MemTotal=[0-9]+ kB' "$LOG" | head -n1)
    echo "[devmeminfo] ${mt}"
else
    echo "[test_devsysinfo] MISS: MemTotal=<digits> kB line absent"
    fail=1
fi
if grep -F -q "[test_devmeminfo] done" "$LOG"; then
    echo "[test_devsysinfo] OK: meminfo fixture completed"
else
    echo "[test_devsysinfo] MISS: meminfo fixture didn't reach done"
    fail=1
fi

# ---- hamsh responsiveness sentinel ----
if grep -F -q "POST_SYSINFO_OK" "$LOG"; then
    echo "[test_devsysinfo] OK: hamsh remains responsive"
else
    echo "[test_devsysinfo] MISS: hamsh died after sysinfo round-trip"
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_devsysinfo] FAIL (qemu rc=$rc)"
    exit 1
fi

echo "[test_devsysinfo] PASS"
