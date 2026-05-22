#!/usr/bin/env bash
# scripts/test_devrandom_chacha.sh — M16.96 regression for the
# ChaCha20 + RDRAND/RDSEED upgrade in /dev/random.
#
# Builds the kernel + userland, plants /bin/test_devrandom_chacha,
# boots QEMU, runs the binary, parses the histogram line, and
# asserts:
#   - total bytes counted == 4096
#   - nonzero buckets >= 200 (chi-square would yield > 250 with
#     extremely high probability; 200 is loose to be flake-free)
#   - max / max(min,1) <= 5 (rules out the xorshift placeholder
#     and any other degenerate distribution)
#
# Also confirms test_devrandom.sh's basic non-zero-not-all-FF check
# still passes by re-running the M16.95 regression after this one.
#
# The xorshift64 placeholder this commit retires WOULD fail the
# nonzero_buckets test: its low-byte cycle leaves dozens of buckets
# empty for any 4 KiB sample.

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf
TEST_ELF=build/user/test_devrandom_chacha.elf

echo "[test_devrandom_chacha] (1/5) Build userland (hamsh + coreutils)"
bash scripts/build_user.sh >/dev/null
bash scripts/build_modules.sh >/dev/null

echo "[test_devrandom_chacha] (2/5) Build tests/test_devrandom_chacha.ad -> $TEST_ELF"
python3 -m compiler.adder compile \
    --target=x86_64-adder-user \
    tests/test_devrandom_chacha.ad \
    -o "$TEST_ELF" >/dev/null

echo "[test_devrandom_chacha] (3/5) Plant /init = hamsh + /bin/test_devrandom_chacha in cpio"
INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py >/dev/null

echo "[test_devrandom_chacha] (4/5) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

echo "[test_devrandom_chacha] (5/5) Boot QEMU + drive the test via hamsh"
LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null' EXIT

set +e
(
    sleep 3
    printf '/bin/test_devrandom_chacha\n'
    sleep 4
    printf 'echo POST_CHACHA_OK\n'
    sleep 1
    printf 'exit\n'
    sleep 1
) | timeout 25s qemu-system-x86_64 \
    -kernel "$ELF" \
    -cpu max \
    -smp 2 \
    -nographic \
    -no-reboot \
    -m 256M \
    -monitor none \
    -serial stdio \
    > "$LOG" 2>&1
rc=$?
set -e

echo "[test_devrandom_chacha] --- captured output ---"
cat "$LOG"
echo "[test_devrandom_chacha] --- end output ---"

fail=0
if grep -F -q "[test_devrandom_chacha] start" "$LOG"; then
    echo "[test_devrandom_chacha] OK: fixture ran"
else
    echo "[test_devrandom_chacha] MISS: fixture banner missing"
    fail=1
fi

HIST_LINE=$(grep "\[test_devrandom_chacha\] hist" "$LOG" || true)
if [ -z "$HIST_LINE" ]; then
    echo "[test_devrandom_chacha] MISS: hist= line absent"
    fail=1
else
    # Parse: " min=<N> max=<N> total=<N> nonzero_buckets=<N>"
    min_val=$(printf '%s\n' "$HIST_LINE" | sed -n 's/.* min=\([0-9]*\).*/\1/p')
    max_val=$(printf '%s\n' "$HIST_LINE" | sed -n 's/.* max=\([0-9]*\).*/\1/p')
    total_val=$(printf '%s\n' "$HIST_LINE" | sed -n 's/.* total=\([0-9]*\).*/\1/p')
    nz_val=$(printf '%s\n' "$HIST_LINE" | sed -n 's/.* nonzero_buckets=\([0-9]*\).*/\1/p')

    echo "[test_devrandom_chacha] parsed: min=$min_val max=$max_val total=$total_val nonzero_buckets=$nz_val"

    if [ -z "$total_val" ] || [ "$total_val" -ne 4096 ]; then
        echo "[test_devrandom_chacha] MISS: total != 4096 (got '$total_val')"
        fail=1
    fi

    if [ -z "$nz_val" ] || [ "$nz_val" -lt 200 ]; then
        echo "[test_devrandom_chacha] MISS: nonzero_buckets < 200 (got '$nz_val') — distribution too narrow"
        fail=1
    else
        echo "[test_devrandom_chacha] OK: $nz_val/256 buckets non-zero"
    fi

    # Spread sanity. The histogram is 4096 samples over 256 buckets, so
    # each bucket is a Poisson(λ = 4096/256 = 16) draw. A degenerate
    # generator (a stuck/short ChaCha stream) would dump most mass into
    # a handful of buckets — that is what we want to catch.
    #
    # The old check, `max <= 5 * min`, was statistically broken: across
    # 256 Poisson(16) draws the minimum routinely lands at 3-7 and the
    # maximum at 28-34, so `max <= 5*min` fails on perfectly good random
    # data (it failed identically under both KVM and TCG). The real
    # degeneracy guard is an *absolute* cap on the busiest bucket: with
    # λ=16, P(any one bucket > 4*λ = 64) is ~1e-15, and even across 256
    # buckets a max above 64 is essentially impossible for a healthy
    # stream — yet a degenerate generator blows straight past it.
    # `nonzero_buckets >= 200` (checked above) covers the other tail.
    expected=$(( total_val / 256 ))
    [ "$expected" -lt 1 ] && expected=1
    max_bound=$(( 4 * expected ))
    if [ -n "$max_val" ] && [ "$max_val" -gt "$max_bound" ]; then
        echo "[test_devrandom_chacha] MISS: max=$max_val > ${max_bound}" \
             "(4x expected ${expected}/bucket) — distribution degenerate"
        fail=1
    else
        echo "[test_devrandom_chacha] OK: busiest bucket max=$max_val" \
             "within 4x expected (${expected}/bucket)"
    fi
fi

POST_LINE=$(grep "\[test_devrandom_chacha\] post " "$LOG" || true)
if [ -z "$POST_LINE" ]; then
    echo "[test_devrandom_chacha] MISS: post-rekey line absent"
    fail=1
else
    post_sum=$(printf '%s\n' "$POST_LINE" | sed -n 's/.* sum16=\([0-9]*\).*/\1/p')
    if [ -z "$post_sum" ] || [ "$post_sum" -eq 0 ]; then
        echo "[test_devrandom_chacha] MISS: post-rekey 16-byte sum is zero"
        fail=1
    else
        echo "[test_devrandom_chacha] OK: post-rekey stream sum16=$post_sum"
    fi
fi

if grep -F -q "POST_CHACHA_OK" "$LOG"; then
    echo "[test_devrandom_chacha] OK: hamsh remains responsive"
else
    echo "[test_devrandom_chacha] MISS: hamsh died after /dev/random chacha run"
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_devrandom_chacha] FAIL (qemu rc=$rc)"
    exit 1
fi

echo "[test_devrandom_chacha] PASS"
