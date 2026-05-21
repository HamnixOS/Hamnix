#!/usr/bin/env bash
# scripts/test_devdiskstats.sh — §13 regression for /dev/diskstats +
# /dev/stat (the system-stat introspection cdevs).
#
# Pipeline mirrors test_devstat.sh: build userland, build both test
# fixtures, plant hamsh as /init, rebuild the kernel, boot QEMU once
# and drive both fixtures over the serial stdio.
#
# PASS markers:
#   - /dev/diskstats: "[test_devdiskstats] field_count=14" — the row
#     carries the Linux-contract 14 whitespace-separated fields.
#   - /dev/stat: "[test_devsysstat] lines_ok" + "ctxt_nonzero" — all
#     six /proc/stat-shape lines present and the real context-switch
#     counter is non-zero.
# Plus each fixture's "done" banner and a hamsh-responsive sentinel.

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-vmlinux.elf
HAMSH_ELF=build/user/hamsh.elf
DS_ELF=build/user/test_devdiskstats.elf
SS_ELF=build/user/test_devsysstat.elf

echo "[test_devdiskstats] (1/5) Build userland (hamsh + coreutils)"
bash scripts/build_user.sh >/dev/null
bash scripts/build_modules.sh >/dev/null

echo "[test_devdiskstats] (2/5) Build tests/test_devdiskstats.ad + test_devsysstat.ad"
python3 -m compiler.adder compile \
    --target=x86_64-adder-user \
    tests/test_devdiskstats.ad \
    -o "$DS_ELF" >/dev/null
python3 -m compiler.adder compile \
    --target=x86_64-adder-user \
    tests/test_devsysstat.ad \
    -o "$SS_ELF" >/dev/null

echo "[test_devdiskstats] (3/5) Plant /init = hamsh + /bin/test_dev{diskstats,sysstat} in cpio"
INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py >/dev/null

echo "[test_devdiskstats] (4/5) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

echo "[test_devdiskstats] (5/5) Boot QEMU + drive both fixtures via hamsh"
LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null' EXIT

set +e
(
    sleep 3
    printf '/bin/test_devdiskstats\n'
    sleep 2
    printf '/bin/test_devsysstat\n'
    sleep 2
    printf 'echo POST_DISKSTATS_OK\n'
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

echo "[test_devdiskstats] --- captured output ---"
cat "$LOG"
echo "[test_devdiskstats] --- end output ---"

fail=0

# ---- /dev/diskstats asserts ----
if grep -F -q "[test_devdiskstats] opened OK" "$LOG"; then
    echo "[test_devdiskstats] OK: /dev/diskstats opened"
else
    echo "[test_devdiskstats] MISS: /dev/diskstats open failed"
    fail=1
fi
if grep -F -q "[test_devdiskstats] field_count=14" "$LOG"; then
    echo "[test_devdiskstats] OK: diskstats row has 14 fields"
else
    echo "[test_devdiskstats] MISS: diskstats row field count wrong"
    fail=1
fi
if grep -F -q "[test_devdiskstats] done" "$LOG"; then
    echo "[test_devdiskstats] OK: diskstats fixture completed"
else
    echo "[test_devdiskstats] MISS: diskstats fixture didn't finish"
    fail=1
fi

# ---- /dev/stat asserts ----
if grep -F -q "[test_devsysstat] opened OK" "$LOG"; then
    echo "[test_devdiskstats] OK: /dev/stat opened"
else
    echo "[test_devdiskstats] MISS: /dev/stat open failed"
    fail=1
fi
if grep -F -q "[test_devsysstat] lines_ok" "$LOG"; then
    echo "[test_devdiskstats] OK: /proc/stat-shape lines all present"
else
    echo "[test_devdiskstats] MISS: /dev/stat missing a line"
    fail=1
fi
if grep -F -q "[test_devsysstat] ctxt_nonzero" "$LOG"; then
    echo "[test_devdiskstats] OK: /dev/stat ctxt counter is real"
else
    echo "[test_devdiskstats] MISS: /dev/stat ctxt is zero"
    fail=1
fi
if grep -F -q "[test_devsysstat] done" "$LOG"; then
    echo "[test_devdiskstats] OK: sysstat fixture completed"
else
    echo "[test_devdiskstats] MISS: sysstat fixture didn't finish"
    fail=1
fi

# ---- hamsh responsiveness sentinel ----
if grep -F -q "POST_DISKSTATS_OK" "$LOG"; then
    echo "[test_devdiskstats] OK: hamsh remains responsive"
else
    echo "[test_devdiskstats] MISS: hamsh died after the round-trip"
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_devdiskstats] FAIL (qemu rc=$rc)"
    exit 1
fi

echo "[test_devdiskstats] PASS"
