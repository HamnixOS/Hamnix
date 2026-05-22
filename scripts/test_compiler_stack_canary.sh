#!/usr/bin/env bash
# scripts/test_compiler_stack_canary.sh — compiler regression for the
# V0 stack-canary support.
#
# Two-part check:
#   1. Host-side asm-shape sanity: compile a tiny .ad that defines one
#      function with Array[16, uint8] and one that doesn't, and assert
#      the asm shape:
#        - canary-needing fn: emits `movq __stack_chk_guard(%rip), %rax`
#          in its prologue and `xorq __stack_chk_guard(%rip), %rax` +
#          `jnz __stack_chk_fail` in its epilogue.
#        - canary-free fn: emits NEITHER of those (no false-positive
#          tagging for tiny leaf-y bodies).
#   2. Userland fixture (tests/test_compiler_stack_canary.ad): compile
#      to an x86_64-adder-user ELF, plant at /bin/test_compiler_stack_
#      canary, boot QEMU + hamsh, drive the binary, then `echo $?` to
#      capture the exit code. Path A asserts the benign-OK marker;
#      Path B asserts the binary exited with code 134 (user-side
#      __stack_chk_fail → sys_exit(134)).
#
# Shape borrowed from scripts/test_compiler_ptr_local.sh.
#
# PASS criteria:
#   host:  canary-needing fn has prologue load + epilogue xor/jnz,
#          canary-free fn has neither.
#   boot:  [canary] benign PASS    AND    "exit: 134"  in the log,
#          and the final wrapper-side [stack_canary] PASS marker
#          aggregates both.

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf
TEST_ELF=build/user/test_compiler_stack_canary.elf

echo "[stack_canary] (1/6) Host-side asm-shape sanity check"
HOST_TMP="$(mktemp -d)"
trap 'rm -rf "$HOST_TMP"' EXIT
cat > "$HOST_TMP/repro.ad" <<'EOF'
def big_array_fn() -> int32:
    arr: Array[16, uint8]
    i: int32 = 0
    while i < 16:
        arr[i] = cast[uint8](i)
        i = i + 1
    return cast[int32](arr[0])

def leaf_no_locals() -> int32:
    return 42
EOF
python3 -m compiler.adder asm --target=x86_64-adder-user \
    "$HOST_TMP/repro.ad" -o "$HOST_TMP/repro.s" >/dev/null

# Split the asm at function boundaries so we can grep PER FUNCTION
# rather than across the whole file (false positives if e.g. some
# other function happens to mention __stack_chk_guard).
awk '/^[a-zA-Z_][a-zA-Z0-9_]*:$/{f=$0; sub(":","",f); next} {if(f)print f"\t"$0}' \
    "$HOST_TMP/repro.s" > "$HOST_TMP/repro.tagged"

if grep -E '^big_array_fn\s.*movq __stack_chk_guard' "$HOST_TMP/repro.tagged" >/dev/null; then
    echo "[stack_canary] OK: big_array_fn prologue loads __stack_chk_guard"
else
    echo "[stack_canary] FAIL: big_array_fn missing canary prologue"
    echo "[stack_canary] --- emitted asm ---"
    cat "$HOST_TMP/repro.s"
    exit 1
fi
if grep -E '^big_array_fn\s.*xorq __stack_chk_guard' "$HOST_TMP/repro.tagged" >/dev/null \
   && grep -E '^big_array_fn\s.*jnz __stack_chk_fail' "$HOST_TMP/repro.tagged" >/dev/null; then
    echo "[stack_canary] OK: big_array_fn epilogue has xor + jnz __stack_chk_fail"
else
    echo "[stack_canary] FAIL: big_array_fn missing canary epilogue"
    echo "[stack_canary] --- emitted asm ---"
    cat "$HOST_TMP/repro.s"
    exit 1
fi
if grep -E '^leaf_no_locals\s.*__stack_chk' "$HOST_TMP/repro.tagged" >/dev/null; then
    echo "[stack_canary] FAIL: leaf_no_locals got an unwanted canary"
    echo "[stack_canary] --- emitted asm ---"
    cat "$HOST_TMP/repro.s"
    exit 1
fi
echo "[stack_canary] OK: leaf_no_locals correctly has no canary"

echo "[stack_canary] (2/6) Build userland (hamsh + coreutils)"
bash scripts/build_user.sh >/dev/null
bash scripts/build_modules.sh >/dev/null

echo "[stack_canary] (3/6) Build tests/test_compiler_stack_canary.ad -> $TEST_ELF"
python3 -m compiler.adder compile \
    --target=x86_64-adder-user \
    tests/test_compiler_stack_canary.ad \
    -o "$TEST_ELF" >/dev/null

echo "[stack_canary] (4/6) Plant /init = hamsh + /bin/test_compiler_stack_canary in cpio"
INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py >/dev/null

echo "[stack_canary] (5/6) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

echo "[stack_canary] (6/6) Boot QEMU + drive the fixture via hamsh"
LOG=$(mktemp)
trap 'rm -f "$LOG"; rm -rf "$HOST_TMP"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null' EXIT

set +e
(
    sleep 3
    # Run the binary; on path B __stack_chk_fail sys_exit(134)'s, and
    # the kernel's sched core prints `task: pid N exited (code=134)`
    # to the serial log when the task gets reaped. That's our
    # canonical "Path B detection fired" marker — distinct from the
    # benign-path code=0 because 134 is glibc's SIGABRT exit code,
    # which __stack_chk_fail uses by convention. Greppable from the
    # wrapper without involving any hamsh $? expansion.
    printf '/bin/test_compiler_stack_canary\n'
    sleep 3
    printf 'exit\n'
    sleep 1
) | timeout 30s qemu-system-x86_64 \
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

echo "[stack_canary] --- captured output ---"
cat "$LOG"
echo "[stack_canary] --- end output ---"

fail=0

check_marker() {
    local marker="$1"
    local label="$2"
    if grep -F -q "$marker" "$LOG"; then
        echo "[stack_canary] OK: $label"
    else
        echo "[stack_canary] MISS: $label ($marker)"
        fail=1
    fi
}

# Path A (benign) markers — both must appear on the way through.
check_marker "[canary] start"           "fixture started"
check_marker "[canary] benign PASS"     "Path A (benign) canary did NOT trip"

# Path B (detection) markers — the "about to overrun" line MUST land,
# the "FAIL: path_b returned" line MUST NOT (control should have been
# taken away by __stack_chk_fail), and the hamsh echo of $? MUST
# report 134 (the user-side __stack_chk_fail's sys_exit code).
check_marker "[canary] about to overrun" "Path B fixture reached overrun call"

if grep -F -q "[canary] FAIL: path_b returned" "$LOG"; then
    echo "[stack_canary] FAIL: path_b returned (canary check did NOT trip)"
    fail=1
fi

if grep -F -q "exited (code=134)" "$LOG"; then
    echo "[stack_canary] OK: Path B exited with code 134 (sys_exit from __stack_chk_fail)"
else
    echo "[stack_canary] MISS: 'exited (code=134)' (Path B's __stack_chk_fail did not fire as expected)"
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[stack_canary] FAIL (qemu rc=$rc)"
    exit 1
fi

echo "[stack_canary] PASS"
