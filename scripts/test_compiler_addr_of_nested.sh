#!/usr/bin/env bash
# Boots QEMU with the compile-time fixture as /init; greps for the PASS marker.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"
TMP="$(mktemp -d)"
trap "rm -rf $TMP" EXIT
INIT_ELF=build/user/test_compiler_addr_of_nested.elf
python3 -m compiler.adder compile --target=x86_64-adder-user \
    tests/test_compiler_addr_of_nested.ad -o "$INIT_ELF" >"$TMP/build.log" 2>&1 || {
    echo "[compiler_nested] FAIL: fixture did not compile"
    cat "$TMP/build.log"
    exit 1
}
INIT_ELF="$INIT_ELF" python3 scripts/build_initramfs.py >"$TMP/initramfs.log" 2>&1
python3 -m compiler.adder compile --target=x86_64-bare-metal init/main.ad >"$TMP/kbuild.log" 2>&1
qemu-system-x86_64 -kernel init/main.elf -nographic \
    -append "console=ttyS0" -no-reboot -m 256M \
    > "$TMP/serial.log" 2>&1 &
QEMU=$!
sleep 30
kill -9 $QEMU 2>/dev/null || true
wait $QEMU 2>/dev/null || true
if grep -q "\[comp_nest\] PASS" "$TMP/serial.log"; then
    echo "[test_compiler_addr_of_nested] PASS"
    exit 0
fi
echo "[test_compiler_addr_of_nested] FAIL"
tail -30 "$TMP/serial.log"
exit 1
