#!/usr/bin/env bash
# scripts/test_compiler_addr_of_nested.sh — compiler regression for
# `&arr[i][j]` on a 2-D Array global. The bug (fixed at 224051b) was
# that gen_index_address dereferenced the inner IndexExpr instead of
# taking its address, so the resulting pointer was NULL.
#
# Boots QEMU with the fixture as /init, greps the serial log for the
# fixture's internal PASS banner (`[comp_nest] PASS`), then emits the
# canonical `[addr_of_nested] PASS` line that run_compiler_tests.sh
# greps.
#
# PASS criterion: `[comp_nest] PASS` in serial log.

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"
TMP="$(mktemp -d)"
trap "rm -rf $TMP" EXIT
INIT_ELF=build/user/test_compiler_addr_of_nested.elf
# _build_lock.sh auto-wipes build/user each run; recreate it first.
mkdir -p build/user
python3 -m compiler.adder compile --target=x86_64-adder-user \
    tests/test_compiler_addr_of_nested.ad -o "$INIT_ELF" >"$TMP/build.log" 2>&1 || {
    echo "[addr_of_nested] FAIL: fixture did not compile"
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
    if grep -q "\[comp_nest\] PASS" "$TMP/serial.log" 2>/dev/null; then break; fi
    kill -0 $QEMU 2>/dev/null || break
done
kill -9 $QEMU 2>/dev/null || true
wait $QEMU 2>/dev/null || true
if grep -q "\[comp_nest\] PASS" "$TMP/serial.log"; then
    echo "[addr_of_nested] PASS"
    exit 0
fi
echo "[addr_of_nested] FAIL"
tail -30 "$TMP/serial.log"
exit 1
