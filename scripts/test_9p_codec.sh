#!/usr/bin/env bash
# scripts/test_9p_codec.sh — 9P V0 codec round-trip regression.
#
# Builds tests/test_9p_codec.ad as a userland ELF, plants it at
# /bin/test_9p_codec, boots QEMU + hamsh, runs the binary, and
# greps the serial log for the [p9codec] PASS banner.
#
# The test covers every T- and R-message in docs/9p.md §3:
# Tversion/Rversion, Tauth/Rauth, Tattach/Rattach, Rerror,
# Tflush/Rflush, Twalk/Rwalk, Topen/Ropen, Tcreate/Rcreate,
# Tread/Rread, Twrite/Rwrite, Tclunk/Rclunk, Tstat/Rstat,
# Twstat/Rwstat. Plus four malformed-input cases: truncated
# header, wrong type byte, oversize body, undersize body.
#
# PASS criterion: "[p9codec] failures=0" AND "[p9codec] PASS"
# both present in the serial log. Any non-zero failures count
# escalates to FAIL with the captured log dumped.
#
# Shape borrowed from scripts/test_p9file.sh (Phase C P9 file
# fixture) — boot once, drive via hamsh stdin, grep stdout.

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf
TEST_ELF=build/user/test_9p_codec.elf

echo "[test_9p_codec] (1/5) Build userland (hamsh + coreutils)"
bash scripts/build_user.sh >/dev/null
bash scripts/build_modules.sh >/dev/null

echo "[test_9p_codec] (2/5) Build tests/test_9p_codec.ad -> $TEST_ELF"
python3 -m compiler.adder compile \
    --target=x86_64-adder-user \
    tests/test_9p_codec.ad \
    -o "$TEST_ELF" >/dev/null

echo "[test_9p_codec] (3/5) Plant /init = hamsh + /bin/test_9p_codec in cpio"
INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py >/dev/null

echo "[test_9p_codec] (4/5) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

echo "[test_9p_codec] (5/5) Boot QEMU + drive /bin/test_9p_codec via hamsh"
LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null' EXIT

set +e
(
    # Mirrors scripts/test_p9file.sh pacing: 3s for kernel smoke to
    # finish before hamsh starts reading stdin.
    sleep 3
    printf '/bin/test_9p_codec\n'
    sleep 3
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

echo "[test_9p_codec] --- captured output ---"
cat "$LOG"
echo "[test_9p_codec] --- end output ---"

fail=0

# Banner first — proves the fixture ran end to end.
if grep -F -q "[p9codec] start" "$LOG"; then
    echo "[test_9p_codec] OK: fixture ran"
else
    echo "[test_9p_codec] MISS: fixture banner missing"
    fail=1
fi

# Per-failure FAIL lines should NEVER appear when the codec is clean.
if grep -F -q "[p9codec] FAIL:" "$LOG"; then
    echo "[test_9p_codec] MISS: per-assertion FAIL line(s) present:"
    grep -F "[p9codec] FAIL:" "$LOG" | sed 's/^/  /'
    fail=1
else
    echo "[test_9p_codec] OK: no per-assertion FAIL lines"
fi

# Aggregate count line — failures=0 is the bar.
if grep -F -q "[p9codec] failures=0" "$LOG"; then
    echo "[test_9p_codec] OK: failures=0"
else
    echo "[test_9p_codec] MISS: failures=0 absent"
    fail=1
fi

# Final PASS line — proves we reached the end of main().
if grep -F -q "[p9codec] PASS" "$LOG"; then
    echo "[test_9p_codec] OK: fixture reached PASS"
else
    echo "[test_9p_codec] MISS: PASS line absent"
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_9p_codec] FAIL (qemu rc=$rc)"
    exit 1
fi

echo "[test_9p_codec] PASS"
