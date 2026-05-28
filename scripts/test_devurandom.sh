#!/usr/bin/env bash
# scripts/test_devurandom.sh — regression for /dev/urandom (the alias
# of /dev/random wired in sys/src/9/port/namec.ad).
#
# Mirrors scripts/test_devrandom.sh's flow:
#   1. Build userland (hamsh + coreutils)
#   2. Build tests/test_devurandom.ad -> build/user/test_devurandom.elf
#   3. Plant /init = hamsh + /bin/test_devurandom in the cpio
#   4. Rebuild kernel image
#   5. Boot QEMU + drive the test via hamsh, then check the log
#
# Assertions:
#   - [test_devurandom] start              fixture launched
#   - [test_devurandom] opened             /dev/urandom open()ed
#   - [test_devurandom] entropy_ok         16 bytes not all-zero/all-ff
#   - [test_devurandom] 4k_jiffies=<N>     4 KiB read latency in jiffies
#                                          (asserted < 100 = 1 s @ HZ=100)
#   - [test_devurandom] varying_ok         consecutive /dev/random reads differ
#   - [test_devurandom] done               clean exit
#
# Also re-verifies /dev/random still works (the same fixture reads it).

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf
TEST_ELF=build/user/test_devurandom.elf

echo "[test_devurandom] (1/5) Build userland (hamsh + coreutils)"
bash scripts/build_user.sh >/dev/null
bash scripts/build_modules.sh >/dev/null

echo "[test_devurandom] (2/5) Build tests/test_devurandom.ad -> $TEST_ELF"
python3 -m compiler.adder compile \
    --target=x86_64-adder-user \
    tests/test_devurandom.ad \
    -o "$TEST_ELF" >/dev/null

echo "[test_devurandom] (3/5) Plant /init = hamsh + /bin/test_devurandom in cpio"
INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py >/dev/null

echo "[test_devurandom] (4/5) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

echo "[test_devurandom] (5/5) Boot QEMU + drive the test via hamsh"
LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null' EXIT

set +e
# Bumped from 3s/2s/1s to 8s/4s/2s — orchestrator hosts under load
# sometimes don't reach hamsh stage-08 (ed-readline-first) in 3s,
# so the first keystrokes get dropped. Same pattern as test_man.sh
# (cef5b15) and test_hamUI_phase1.sh.
(
    sleep 8
    printf '/bin/test_devurandom\n'
    sleep 4
    printf 'echo POST_URANDOM_OK\n'
    sleep 2
    printf 'exit\n'
    sleep 2
) | timeout 30s qemu-system-x86_64 \
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

echo "[test_devurandom] --- captured output ---"
cat "$LOG"
echo "[test_devurandom] --- end output ---"

fail=0
need_markers=(
    "[test_devurandom] start"
    "[test_devurandom] opened"
    "[test_devurandom] entropy_ok"
    "[test_devurandom] varying_ok"
    "[test_devurandom] done"
)
for m in "${need_markers[@]}"; do
    if grep -F -q "$m" "$LOG"; then
        echo "[test_devurandom] OK: marker '$m'"
    else
        echo "[test_devurandom] MISS: marker '$m'"
        fail=1
    fi
done

# 4 KiB latency check.
jiffies_line=$(grep "\[test_devurandom\] 4k_jiffies=" "$LOG" || true)
if [ -z "$jiffies_line" ]; then
    echo "[test_devurandom] MISS: 4k_jiffies= line absent"
    fail=1
else
    jval=${jiffies_line##*4k_jiffies=}
    jval=${jval%%[!0-9]*}
    if [ -z "$jval" ]; then
        echo "[test_devurandom] MISS: 4k_jiffies= value unparseable ('$jiffies_line')"
        fail=1
    elif [ "$jval" -ge 100 ]; then
        echo "[test_devurandom] FAIL: 4 KiB read took $jval jiffies (>= 1 s)"
        fail=1
    else
        echo "[test_devurandom] OK: 4 KiB read in $jval jiffies"
    fi
fi

if grep -F -q "POST_URANDOM_OK" "$LOG"; then
    echo "[test_devurandom] OK: hamsh remains responsive"
else
    echo "[test_devurandom] MISS: hamsh died after /dev/urandom round-trip"
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_devurandom] FAIL (qemu rc=$rc)"
    exit 1
fi

echo "[test_devurandom] PASS"
