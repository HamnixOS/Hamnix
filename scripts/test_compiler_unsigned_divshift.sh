#!/usr/bin/env bash
# scripts/test_compiler_unsigned_divshift.sh — compiler regression for
# operand-signedness-aware lowering of `>>`, `/`, `//` and `%`.
#
# The x86_64 backend must emit:
#   sarq  (not shrq) for a signed `>>`,  shrq for an unsigned `>>`
#   idivq (not divq) for a signed `/`/`%`, divq for an unsigned `/`/`%`
# Emitting the unsigned form for a negative operand, or the signed form
# for an unsigned operand with the high bit set, corrupts the result.
#
# Boots QEMU with tests/test_compiler_unsigned_divshift.ad as /init and
# greps the serial log for the fixture's internal PASS banner
# (`[unsigned_divshift] PASS`), then emits the canonical
# `[unsigned_divshift] PASS` line that run_compiler_tests.sh greps.
#
# PASS criterion: `[unsigned_divshift] PASS` in serial log.

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"
TMP="$(mktemp -d)"
trap "rm -rf $TMP" EXIT
INIT_ELF=build/user/test_compiler_unsigned_divshift.elf
# _build_lock.sh auto-wipes build/user each run; recreate it before the
# compiler links into it.
mkdir -p build/user
python3 -m compiler.adder compile --target=x86_64-adder-user \
    tests/test_compiler_unsigned_divshift.ad -o "$INIT_ELF" >"$TMP/build.log" 2>&1 || {
    echo "[unsigned_divshift] FAIL: fixture did not compile"
    cat "$TMP/build.log"
    exit 1
}
INIT_ELF="$INIT_ELF" python3 scripts/build_initramfs.py >"$TMP/initramfs.log" 2>&1
python3 -m compiler.adder compile --target=x86_64-bare-metal init/main.ad >"$TMP/kbuild.log" 2>&1
qemu-system-x86_64 -kernel init/main.elf -nographic \
    -append "console=ttyS0" -no-reboot -m 256M \
    > "$TMP/serial.log" 2>&1 &
QEMU=$!
for _i in $(seq 1 60); do
    sleep 1
    if grep -q "\[unsigned_divshift\] PASS" "$TMP/serial.log" 2>/dev/null; then break; fi
    kill -0 $QEMU 2>/dev/null || break
done
kill -9 $QEMU 2>/dev/null || true
wait $QEMU 2>/dev/null || true
if grep -q "\[unsigned_divshift\] PASS" "$TMP/serial.log"; then
    echo "[unsigned_divshift] PASS"
    exit 0
fi
echo "[unsigned_divshift] FAIL"
tail -30 "$TMP/serial.log"
exit 1
