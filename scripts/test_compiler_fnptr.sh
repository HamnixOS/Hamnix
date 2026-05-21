#!/usr/bin/env bash
# scripts/test_compiler_fnptr.sh — compiler regression for first-class
# function pointers (`Fn[R, A...]`).
#
# Adder gained a real first-class function-pointer type. A function
# name used as a value yields a `Fn[...]` value; a value of that type
# is callable with ordinary call syntax. Indirect calls go through the
# SysV-AMD64 calling convention (args in rdi/rsi/rdx/rcx/r8/r9 + stack
# for the rest, `call *` through the register operand, result in rax),
# reusing the same argument-marshaling path a direct call uses.
#
# Before this, indirect calls were an `asm_volatile("call *%rax")`-
# shaped hack: the kernel's IRQ dispatch table (call_irq_handler),
# the block-device vtable, the netfilter hook chain, and the
# timer/hrtimer/kthread dispatchers all routed through it.
#
# Two-layer test (mirrors scripts/test_compiler_string_global.sh):
#   1. Host-side asm-shape check: compile a minimal reproducer with
#      `compiler.adder asm` and assert
#        - an indirect call lowers to `call *%r11` (not `call <name>`);
#        - a direct call to a real function still lowers to `call add`;
#        - a function-pointer global is emitted as `.quad <func>`.
#   2. Userland fixture (tests/test_compiler_fnptr.ad): build as an
#      x86_64-adder-user ELF, plant as /init, boot QEMU, grep the
#      serial log for the `[fnptr] PASS` banner. The fixture exercises
#      a function pointer in a local, a global, a struct field, an
#      array (dispatch table), passed as an argument, and a 7-argument
#      indirect call (rdi..r9 + one stack arg) returning a value.
#
# PASS criterion (host side):   `call *%r11` present, `call add`
#                                present, `.quad add` global init.
# PASS criterion (kernel side): `[fnptr] PASS` in serial log.

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"
TMP="$(mktemp -d)"
trap "rm -rf $TMP" EXIT

echo "[fnptr] (1/3) Host-side asm-shape sanity check"
cat > "$TMP/repro.ad" <<'EOF'
def add(a: int64, b: int64) -> int64:
    return a + b

g_fn: Fn[int64, int64, int64] = add

def call_indirect(f: Fn[int64, int64, int64], x: int64, y: int64) -> int64:
    return f(x, y)

def call_direct(x: int64, y: int64) -> int64:
    return add(x, y)
EOF
python3 -m compiler.adder asm --target=x86_64-adder-user \
    "$TMP/repro.ad" -o "$TMP/repro.s" >/dev/null

shape_ok=1
if grep -qE '^[[:space:]]+call \*%r11' "$TMP/repro.s"; then
    echo "[fnptr] OK: indirect call lowers to 'call *%r11'"
else
    echo "[fnptr] FAIL: no 'call *%r11' indirect call emitted"
    shape_ok=0
fi
if grep -qE '^[[:space:]]+call add$' "$TMP/repro.s"; then
    echo "[fnptr] OK: direct call still lowers to 'call add'"
else
    echo "[fnptr] FAIL: direct call to a real function did not emit 'call add'"
    shape_ok=0
fi
if grep -qE '^[[:space:]]*\.quad add' "$TMP/repro.s"; then
    echo "[fnptr] OK: function-pointer global emitted as '.quad add'"
else
    echo "[fnptr] FAIL: function-pointer global not emitted as '.quad add'"
    shape_ok=0
fi
if [ "$shape_ok" -ne 1 ]; then
    echo "[fnptr] --- emitted asm ---"
    cat "$TMP/repro.s"
    exit 1
fi

echo "[fnptr] (2/3) Build tests/test_compiler_fnptr.ad"
INIT_ELF=build/user/test_compiler_fnptr.elf
# _build_lock.sh auto-wipes build/user each run; recreate it first.
mkdir -p build/user
if ! python3 -m compiler.adder compile --target=x86_64-adder-user \
        tests/test_compiler_fnptr.ad -o "$INIT_ELF" \
        >"$TMP/build.log" 2>&1; then
    echo "[fnptr] FAIL: fixture did not compile"
    cat "$TMP/build.log"
    exit 1
fi

INIT_ELF="$INIT_ELF" python3 scripts/build_initramfs.py >"$TMP/initramfs.log" 2>&1
python3 -m compiler.adder compile --target=x86_64-bare-metal init/main.ad \
    >"$TMP/kbuild.log" 2>&1

echo "[fnptr] (3/3) Boot QEMU + grep for [fnptr] PASS"
qemu-system-x86_64 -kernel init/main.elf -nographic \
    -append "console=ttyS0" -no-reboot -m 256M \
    > "$TMP/serial.log" 2>&1 &
QEMU=$!
for _i in $(seq 1 60); do
    sleep 1
    if grep -q "\[fnptr\] PASS" "$TMP/serial.log" 2>/dev/null; then break; fi
    if grep -q "\[fnptr\] FAIL" "$TMP/serial.log" 2>/dev/null; then break; fi
    kill -0 $QEMU 2>/dev/null || break
done
kill -9 $QEMU 2>/dev/null || true
wait $QEMU 2>/dev/null || true

if grep -q "\[fnptr\] PASS" "$TMP/serial.log"; then
    echo "[fnptr] PASS"
    exit 0
fi

echo "[fnptr] FAIL"
tail -40 "$TMP/serial.log"
exit 1
