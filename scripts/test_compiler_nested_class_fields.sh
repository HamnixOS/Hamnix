#!/usr/bin/env bash
# Boots QEMU with tests/test_compiler_nested_class_fields.ad as /init;
# greps for the [nested_class] PASS marker.
#
# Verifies whether nested class-instance fields alias each other —
# the V2 RSA-PSS agent (commit 3c4f152) hit aliasing in
# `class Outer { a: Inner; b: Inner }` and had to flatten into
# raw byte buffers + module-scope bigints. If this test FAILs, the
# quirk is real and needs codegen attention.
#
# When the bug is fixed and this test starts passing, update
# memory/feedback_compiler_quirks.md to reflect.

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$PROJ_ROOT/scripts/_build_lock.sh"

cd "$PROJ_ROOT"
TMP="$(mktemp -d)"
trap "rm -rf $TMP" EXIT

INIT_ELF=build/user/test_compiler_nested_class_fields.elf
# _build_lock.sh auto-wipes build/user each run; recreate it first.
mkdir -p build/user
python3 -m compiler.adder compile --target=x86_64-adder-user \
    tests/test_compiler_nested_class_fields.ad -o "$INIT_ELF" \
    >"$TMP/build.log" 2>&1 || {
    echo "[nested_class] FAIL: fixture did not compile"
    cat "$TMP/build.log"
    exit 1
}
INIT_ELF="$INIT_ELF" python3 scripts/build_initramfs.py >"$TMP/initramfs.log" 2>&1
python3 -m compiler.adder compile --target=x86_64-bare-metal \
    init/main.ad >"$TMP/kbuild.log" 2>&1

qemu-system-x86_64 -kernel init/main.elf -nographic \
    -append "console=ttyS0" -no-reboot -m 256M \
    > "$TMP/serial.log" 2>&1 &
QEMU=$!
for _i in $(seq 1 60); do
    sleep 1
    if grep -q "\[nested_class\] PASS" "$TMP/serial.log" 2>/dev/null; then break; fi
    kill -0 $QEMU 2>/dev/null || break
done
kill -9 $QEMU 2>/dev/null || true
wait $QEMU 2>/dev/null || true

if grep -q "\[nested_class\] PASS" "$TMP/serial.log"; then
    echo "[test_compiler_nested_class_fields] PASS"
    exit 0
fi

echo "[test_compiler_nested_class_fields] FAIL (quirk active or compile-time issue)"
tail -30 "$TMP/serial.log"
exit 1
