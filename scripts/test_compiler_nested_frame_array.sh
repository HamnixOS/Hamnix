#!/usr/bin/env bash
# scripts/test_compiler_nested_frame_array.sh — guards the abstract U9
# nested-frame Array pattern (see memory/feedback_compiler_quirks.md
# "Nested fixed-size Array locals across call frames"). The kernel-side
# trigger surfaces in the resolve_path chain inside _u_openat; this
# fixture guards the minimum-depth userland reproducer.
#
# Boots QEMU with the fixture as /init, greps the serial log for the
# fixture's `[nested_frame_array] PASS` marker.
#
# CURRENT MODE: PASS-expected. The minimal userland repro PASSES on
# current main even though the U9 bug exists in the kernel-side
# context — see the .ad header for the empirical finding.
#
# If a future agent expands the .ad to a shape that DOES exhibit the
# bug at the userland level, flip this script to XFAIL semantics:
# replace the `grep -q ... && exit 0 || exit 1` block below with the
# inverted form
#       if grep -q "\[nested_frame_array\] PASS" "$TMP/serial.log"; then
#           echo "[nested_frame_array] XFAIL-FIXED — flip this script back"
#           exit 1
#       fi
#       echo "[nested_frame_array] XFAIL (bug present as expected)"
#       exit 0
# until the compiler fix lands. See CONTRIBUTING.md "Compiler
# regression suite" -> XFAIL fixtures.

. "$(dirname "$0")/_build_lock.sh"

set -uo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"
TMP="$(mktemp -d)"
trap "rm -rf $TMP" EXIT
INIT_ELF=build/user/test_compiler_nested_frame_array.elf
# _build_lock.sh auto-wipes build/user each run; recreate it first.
mkdir -p build/user

if ! python3 -m compiler.adder compile --target=x86_64-adder-user \
        tests/test_compiler_nested_frame_array.ad -o "$INIT_ELF" \
        >"$TMP/build.log" 2>&1; then
    echo "[nested_frame_array] FAIL: fixture did not compile"
    cat "$TMP/build.log"
    exit 1
fi

INIT_ELF="$INIT_ELF" python3 scripts/build_initramfs.py >"$TMP/initramfs.log" 2>&1
python3 -m compiler.adder compile --target=x86_64-bare-metal init/main.ad >"$TMP/kbuild.log" 2>&1

qemu-system-x86_64 -kernel init/main.elf -nographic \
    -append "console=ttyS0" -no-reboot -m 256M \
    > "$TMP/serial.log" 2>&1 &
QEMU=$!
for _i in $(seq 1 60); do
    sleep 1
    if grep -q "\[nested_frame_array\] PASS" "$TMP/serial.log" 2>/dev/null; then break; fi
    kill -0 $QEMU 2>/dev/null || break
done
kill -9 $QEMU 2>/dev/null || true
wait $QEMU 2>/dev/null || true

if grep -q "\[nested_frame_array\] PASS" "$TMP/serial.log"; then
    echo "[nested_frame_array] PASS"
    exit 0
fi

echo "[nested_frame_array] FAIL"
tail -30 "$TMP/serial.log"
exit 1
