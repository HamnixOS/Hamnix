#!/usr/bin/env bash
# scripts/test_compiler_string_global.sh — compiler regression for
# string-literal-initialised globals.
#
# The bug: compiler/codegen_x86.py gen_data()'s emit_init only
# accepted an IntLiteral initialiser, so a global typed
# `Array[N, uint8]` could not be initialised from a string literal —
# it raised "must have an integer initializer". Every kernel string
# constant had to be materialised byte-by-byte at runtime.
#
# The fix emits the literal's bytes straight into `.data`, NUL-padded
# to the declared array length.
#
# Two-layer test (mirrors scripts/test_compiler_ptr_local.sh):
#   1. Host-side asm-shape check: compile a minimal string-global
#      reproducer with `compiler.adder asm` and assert the global is
#      emitted as `.ascii "..."` + `.zero <pad>`.
#   2. Userland fixture (tests/test_compiler_string_global.ad): build
#      as an x86_64-adder-user ELF, plant as /init, boot QEMU, grep
#      the serial log for the `[string_global] PASS` banner.
#
# PASS criterion (host side):   `.ascii "<text>"` line emitted for the
#                                global, followed by a `.zero` pad.
# PASS criterion (kernel side): `[string_global] PASS` in serial log.

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"
TMP="$(mktemp -d)"
trap "rm -rf $TMP" EXIT

echo "[string_global] (1/3) Host-side asm-shape sanity check"
cat > "$TMP/repro.ad" <<'EOF'
banner: Array[16, uint8] = "hello"
def get_banner() -> Ptr[uint8]:
    return &banner[0]
EOF
python3 -m compiler.adder asm --target=x86_64-adder-user \
    "$TMP/repro.ad" -o "$TMP/repro.s" >/dev/null

if grep -qE '^[[:space:]]*\.ascii "hello"' "$TMP/repro.s" \
   && grep -qE '^[[:space:]]*\.zero 11' "$TMP/repro.s"; then
    echo "[string_global] OK: string global emitted as .ascii + .zero pad"
else
    echo "[string_global] FAIL: string global not emitted correctly"
    echo "[string_global] --- emitted asm (data) ---"
    grep -A3 'banner:' "$TMP/repro.s" || cat "$TMP/repro.s"
    exit 1
fi

echo "[string_global] (2/3) Build tests/test_compiler_string_global.ad"
INIT_ELF=build/user/test_compiler_string_global.elf
# _build_lock.sh auto-wipes build/user each run; recreate it first.
mkdir -p build/user
if ! python3 -m compiler.adder compile --target=x86_64-adder-user \
        tests/test_compiler_string_global.ad -o "$INIT_ELF" \
        >"$TMP/build.log" 2>&1; then
    echo "[string_global] FAIL: fixture did not compile"
    cat "$TMP/build.log"
    exit 1
fi

INIT_ELF="$INIT_ELF" python3 scripts/build_initramfs.py >"$TMP/initramfs.log" 2>&1
python3 -m compiler.adder compile --target=x86_64-bare-metal init/main.ad \
    >"$TMP/kbuild.log" 2>&1

echo "[string_global] (3/3) Boot QEMU + grep for [string_global] PASS"
qemu-system-x86_64 -kernel init/main.elf -nographic \
    -append "console=ttyS0" -no-reboot -m 256M \
    > "$TMP/serial.log" 2>&1 &
QEMU=$!
for _i in $(seq 1 60); do
    sleep 1
    if grep -q "\[string_global\] PASS" "$TMP/serial.log" 2>/dev/null; then break; fi
    if grep -q "\[string_global\] FAIL" "$TMP/serial.log" 2>/dev/null; then break; fi
    kill -0 $QEMU 2>/dev/null || break
done
kill -9 $QEMU 2>/dev/null || true
wait $QEMU 2>/dev/null || true

if grep -q "\[string_global\] PASS" "$TMP/serial.log"; then
    echo "[string_global] PASS"
    exit 0
fi

echo "[string_global] FAIL"
tail -30 "$TMP/serial.log"
exit 1
