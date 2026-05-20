#!/usr/bin/env bash
# scripts/test_compiler_cast_arr_u32.sh — compiler regression for
# `cast[uint64](arr32[i])` where arr32 is Array[N, uint32]. The M16.97
# memory note claimed cast-then-equal leaked stale upper bits across
# the compare; this fixture proves the quirk is phantom on current main
# (the asm shape is movl + auto-zero-extend, which is correct).
#
# Boots QEMU with the fixture as /init, greps the serial log for the
# fixture's internal PASS banner (`[comp_cast32] PASS`), then emits the
# canonical `[cast_arr_u32] PASS` line that run_compiler_tests.sh greps.
#
# PASS criterion: `[comp_cast32] PASS` in serial log.

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"
TMP="$(mktemp -d)"
trap "rm -rf $TMP" EXIT
INIT_ELF=build/user/test_compiler_cast_arr_u32.elf
# _build_lock.sh auto-wipes build/user each run; recreate it first.
mkdir -p build/user
python3 -m compiler.adder compile --target=x86_64-adder-user \
    tests/test_compiler_cast_arr_u32.ad -o "$INIT_ELF" >"$TMP/build.log" 2>&1 || {
    echo "[cast_arr_u32] FAIL: fixture did not compile"
    cat "$TMP/build.log"
    exit 1
}
INIT_ELF="$INIT_ELF" python3 scripts/build_initramfs.py >"$TMP/initramfs.log" 2>&1
python3 -m compiler.adder compile --target=x86_64-bare-metal init/main.ad >"$TMP/kbuild.log" 2>&1
qemu-system-x86_64 -kernel init/main.elf -nographic \
    -append "console=ttyS0" -no-reboot -m 256M \
    > "$TMP/serial.log" 2>&1 &
QEMU=$!
# Early-out only on the fixture's specific PASS banner. The previous
# loop matched a bare "PASS" which fires in iteration 1 — many early
# boot lines contain "PASS" (atkbd self-test, auxmouse self-test, etc.)
# — and breaks out of the wait before the kernel has even reached the
# SMP bring-up, let alone user-mode. Killing qemu that early stops the
# serial-log capture mid-`SMP: sending SIPI vector 0x8`, which makes
# the failure look like an AP-bringup hang instead of a polling-loop
# bug. Match the exact marker the second grep checks for.
for _i in $(seq 1 60); do
    sleep 1
    if grep -q "\[comp_cast32\] PASS" "$TMP/serial.log" 2>/dev/null; then break; fi
    kill -0 $QEMU 2>/dev/null || break
done
kill -9 $QEMU 2>/dev/null || true
wait $QEMU 2>/dev/null || true
if grep -q "\[comp_cast32\] PASS" "$TMP/serial.log"; then
    echo "[cast_arr_u32] PASS"
    exit 0
fi
echo "[cast_arr_u32] FAIL"
tail -30 "$TMP/serial.log"
exit 1
