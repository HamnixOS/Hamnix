#!/usr/bin/env bash
# scripts/test_devrandom.sh — M16.95 regression for /dev/random.
#
# Mirrors test_devcons.sh / test_devtime.sh: rebuild user + kernel,
# boot QEMU, run /bin/test_devrandom, assert the 16 emitted bytes are
# NOT all 0 and NOT all 255 (a coarse "entropy is varying" check
# appropriate to the xorshift64 placeholder shipped in M16.95).

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-vmlinux.elf
HAMSH_ELF=build/user/hamsh.elf
TEST_ELF=build/user/test_devrandom.elf

echo "[test_devrandom] (1/5) Build userland (hamsh + coreutils)"
bash scripts/build_user.sh >/dev/null
bash scripts/build_modules.sh >/dev/null

echo "[test_devrandom] (2/5) Build tests/test_devrandom.ad -> $TEST_ELF"
python3 -m compiler.adder compile \
    --target=x86_64-adder-user \
    tests/test_devrandom.ad \
    -o "$TEST_ELF" >/dev/null

echo "[test_devrandom] (3/5) Plant /init = hamsh + /bin/test_devrandom in cpio"
INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py >/dev/null

echo "[test_devrandom] (4/5) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

echo "[test_devrandom] (5/5) Boot QEMU + drive the test via hamsh"
LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null' EXIT

set +e
(
    sleep 3
    printf '/bin/test_devrandom\n'
    sleep 2
    printf 'echo POST_RANDOM_OK\n'
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

echo "[test_devrandom] --- captured output ---"
cat "$LOG"
echo "[test_devrandom] --- end output ---"

fail=0
if grep -F -q "[test_devrandom] start" "$LOG"; then
    echo "[test_devrandom] OK: fixture ran"
else
    echo "[test_devrandom] MISS: fixture banner missing"
    fail=1
fi

# Pull the bytes= line out, parse the 16 space-separated decimals.
BYTES_LINE=$(grep "\[test_devrandom\] bytes=" "$LOG" || true)
if [ -z "$BYTES_LINE" ]; then
    echo "[test_devrandom] MISS: bytes= line absent"
    fail=1
else
    # Strip the prefix; leaves a leading space and 16 numbers.
    NUMS=${BYTES_LINE#*bytes=}
    # Count zeros and 255s. xorshift64 from a non-zero seed never
    # produces an all-zero 16-byte run (cycle excludes 0), and even
    # less likely to produce all 255s — these are sanity bounds.
    zero_count=0
    ff_count=0
    total=0
    for n in $NUMS; do
        # Skip non-numeric tokens (defensive — shouldn't happen, but
        # let CR/LF artifacts pass through silently).
        case "$n" in
            ''|*[!0-9]*) continue ;;
        esac
        total=$((total + 1))
        if [ "$n" -eq 0 ]; then
            zero_count=$((zero_count + 1))
        fi
        if [ "$n" -eq 255 ]; then
            ff_count=$((ff_count + 1))
        fi
    done
    echo "[test_devrandom] parsed $total bytes ($zero_count zero, $ff_count 0xff)"
    if [ "$total" -lt 16 ]; then
        echo "[test_devrandom] MISS: expected 16 bytes, got $total"
        fail=1
    elif [ "$zero_count" -eq 16 ]; then
        echo "[test_devrandom] MISS: all 16 bytes were zero (PRNG not seeded?)"
        fail=1
    elif [ "$ff_count" -eq 16 ]; then
        echo "[test_devrandom] MISS: all 16 bytes were 0xff (degenerate state?)"
        fail=1
    else
        echo "[test_devrandom] OK: /dev/random produced varying bytes"
    fi
fi

if grep -F -q "POST_RANDOM_OK" "$LOG"; then
    echo "[test_devrandom] OK: hamsh remains responsive"
else
    echo "[test_devrandom] MISS: hamsh died after /dev/random round-trip"
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_devrandom] FAIL (qemu rc=$rc)"
    exit 1
fi

echo "[test_devrandom] PASS"
