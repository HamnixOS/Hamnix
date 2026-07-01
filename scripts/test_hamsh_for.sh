#!/usr/bin/env bash
# scripts/test_hamsh_for.sh — POSIX `for VAR in ITEM... { BODY }` loops
# (QA-N18).
#
# hamsh historically parsed the for-loop iterable as ONE expression
# (parse_expr), so it only accepted the spec's `for f in $files { }`
# shape and a single bareword did not iterate at all:
#
#   * `for f in a b c { echo $f }`  -> `parse error: expected {`
#     (parse_expr consumed `a`, then parse_block hit `b`, not `{`).
#   * `for f in solo { echo $f }`   -> NO iteration / no output
#     (a lone scalar word was not a list).
#
# The fix (user/hamsh.ad parse_for/exec_for): the for-loop now collects
# ONE OR MORE item words — with the SAME word machinery as command
# arguments, so `$var`/globs/`text$var` fusion behave identically
# (QA-N7/N16/N20) — terminated by the opening `{`. exec_for expands the
# item words (glob + `$list` interpolation) into a flat sequence and runs
# the body once per item with VAR bound to it:
#
#   for x in a b c { }   -> 3 iterations (x=a, x=b, x=c)
#   for f in solo   { }   -> 1 iteration  (f=solo)
#   for y in $xs two { }  -> $xs's words, then `two`
#
# Strategy: boot hamsh as /init, drive its serial, echo per-iteration
# markers and assert them. NB: a freshly-booted hamsh drops the FIRST
# serial command line, so we send a warm-up marker line first.

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf

echo "[test_hamsh_for] (1/3) Build userland"
bash scripts/build_user.sh >/dev/null

echo "[test_hamsh_for] (2/3) Plant /init = hamsh in initramfs"
INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py >/dev/null

echo "[test_hamsh_for] (3/3) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null' EXIT

set +e
(
    sleep 3
    # A fresh hamsh drops its FIRST serial line, so lead with a harmless
    # warm-up marker (re-sent) before the real cases. Each case is
    # SELF-CONTAINED on ONE serial line so a per-line drop can't decouple
    # a set-up from its read-back.
    printf 'echo WARMUP_MARKER\n'
    sleep 2
    printf 'echo WARMUP_MARKER\n'
    sleep 2
    # 1. multi-word list: three iterations, VAR bound to each word.
    printf 'for x in a b c { echo L_$x }\n'
    sleep 2
    # 2. single bareword: exactly ONE iteration (was zero before).
    printf 'for f in solo { echo S_$f }\n'
    sleep 2
    # 3. $var that expands to a scalar word, then a trailing literal.
    printf 'xs=one ; for y in $xs two { echo Y_$y }\n'
    sleep 2
    # Re-send case 1 (a fresh hamsh may still have been warming up).
    printf 'for x in a b c { echo L_$x }\n'
    sleep 2
    printf 'echo ALL_DONE_MARKER\n'
    sleep 2
    printf 'exit\n'
    sleep 2
) | timeout 60s qemu-system-x86_64 \
    -kernel "$ELF" \
    -smp 2 \
    -nographic \
    -no-reboot \
    -m 256M \
    -monitor none \
    -serial stdio \
    > "$LOG" 2>&1
set -e

echo "[test_hamsh_for] --- captured output ---"
cat "$LOG"
echo "[test_hamsh_for] --- end output ---"

fail=0
check() {
    if grep -F -q "$1" "$LOG"; then
        echo "[test_hamsh_for] OK: $2"
    else
        echo "[test_hamsh_for] MISS ('$1'): $2"
        fail=1
    fi
}

# Case 1: three iterations over the bareword list.
check "L_a"     "for x in a b c -> iteration x=a"
check "L_b"     "for x in a b c -> iteration x=b"
check "L_c"     "for x in a b c -> iteration x=c"
# Case 2: single bareword iterates exactly once.
check "S_solo"  "for f in solo -> single iteration f=solo"
# Case 3: \$var + trailing literal.
check "Y_one"   "for y in \$xs two -> \$xs expands to 'one'"
check "Y_two"   "for y in \$xs two -> trailing literal 'two'"

if [ "$fail" -ne 0 ]; then
    echo "[test_hamsh_for] FAIL"
    exit 1
fi
echo "[test_hamsh_for] PASS"
