#!/usr/bin/env bash
# scripts/test_hamsh_with.sh — HAMSH_SPEC §19 (#111): `with` context
# managers married to Plan 9 binds.
#
# The distinctive rung: Python's `with` fused with a Plan 9 bind. Inside
#   with bind(SRC, DST):
#       ...
# the graft SRC->DST is live IN THE CURRENT process; at the block's end
# it is UNDONE — even if the body fails. Neither Python nor rc has this.
#
# This gate proves, over the serial console, using `cat /proc/self/ns`
# as the ground-truth namespace dump (a bound DST appears as a line):
#   A. ROUND-TRIP (brace form): DST is bound INSIDE the block and GONE
#      after it — auto-undo on the normal-exit path.
#   B. DIFFERENTIAL (indent form ≡ brace form): the SAME `with` in a
#      Python-indent suite round-trips identically.
#   C. ERROR PATH: a `with bind(...)` whose body FAILS still unbinds —
#      the leaked-bind-is-worse-than-no-feature contract.
#   D. `as NAME` binds the DST path for the body to name.
set -euo pipefail

. "$(dirname "$0")/_build_lock.sh"

PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf

bash scripts/build_user.sh >/dev/null
INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py >/dev/null
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal init/main.ad -o "$ELF" >/dev/null

LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1' EXIT

set +e
(
    sleep 3
    # A. brace-form round-trip.
    printf 'echo WITH_BRACE_IN\n'
    sleep 1
    printf 'with bind(/tmp, /wm_brace) { cat /proc/self/ns }\n'
    sleep 2
    printf 'echo WITH_BRACE_OUT\n'
    sleep 1
    printf 'cat /proc/self/ns\n'
    sleep 2
    # B. indent-form round-trip (differential ≡ brace).
    printf 'echo WITH_INDENT_IN\n'
    sleep 1
    printf 'with bind(/tmp, /wm_indent):\n    cat /proc/self/ns\n\n'
    sleep 2
    printf 'echo WITH_INDENT_OUT\n'
    sleep 1
    printf 'cat /proc/self/ns\n'
    sleep 2
    # C. error path — body fails (nonzero), the bind must still be undone.
    printf 'echo WITH_ERR_IN\n'
    sleep 1
    printf 'with bind(/tmp, /wm_err) { false }\n'
    sleep 2
    printf 'echo WITH_ERR_OUT\n'
    sleep 1
    printf 'cat /proc/self/ns\n'
    sleep 2
    # D. `as NAME` yields the bound path inside the body.
    printf 'echo WITH_AS_IN\n'
    sleep 1
    printf 'with bind(/tmp, /wm_as) as wp { echo WITH_AS_NAME $wp }\n'
    sleep 2
    printf 'echo WITH_DONE\n'
    sleep 1
    printf 'exit\n'
    sleep 1
) | timeout 90s qemu-system-x86_64 \
    -kernel "$ELF" -smp 2 -nographic -no-reboot -m 256M \
    -monitor none -serial stdio > "$LOG" 2>&1
set -e

echo "[test_hamsh_with] --- captured ---"
cat "$LOG"
echo "[test_hamsh_with] --- end ---"

fail=0

brace_inside=$(sed -n '/WITH_BRACE_IN/,/WITH_BRACE_OUT/p' "$LOG")
brace_after=$(sed -n '/WITH_BRACE_OUT/,/WITH_INDENT_IN/p' "$LOG")
indent_inside=$(sed -n '/WITH_INDENT_IN/,/WITH_INDENT_OUT/p' "$LOG")
indent_after=$(sed -n '/WITH_INDENT_OUT/,/WITH_ERR_IN/p' "$LOG")
err_after=$(sed -n '/WITH_ERR_OUT/,/WITH_AS_IN/p' "$LOG")

# A. brace-form round-trip: bound inside, gone after.
if echo "$brace_inside" | grep -F -q "/wm_brace"; then
    echo "[test_hamsh_with] OK: with bind — DST is bound INSIDE the block"
else
    echo "[test_hamsh_with] FAIL: with bind — DST not bound inside the block"; fail=1
fi
if echo "$brace_after" | grep -F -q "/wm_brace"; then
    echo "[test_hamsh_with] FAIL: with bind LEAKED — DST still bound after the block"; fail=1
else
    echo "[test_hamsh_with] OK: with bind auto-undo — DST gone after the block"
fi

# B. indent-form round-trip (differential ≡).
if echo "$indent_inside" | grep -F -q "/wm_indent"; then
    echo "[test_hamsh_with] OK: indent-form with bind — bound inside"
else
    echo "[test_hamsh_with] FAIL: indent-form with bind — not bound inside"; fail=1
fi
if echo "$indent_after" | grep -F -q "/wm_indent"; then
    echo "[test_hamsh_with] FAIL: indent-form with bind LEAKED after the block"; fail=1
else
    echo "[test_hamsh_with] OK: indent-form with bind auto-undo (≡ brace form)"
fi

# C. error path: the bind is undone even though the body failed.
if echo "$err_after" | grep -F -q "/wm_err"; then
    echo "[test_hamsh_with] FAIL: error-path LEAK — failed body left DST bound"; fail=1
else
    echo "[test_hamsh_with] OK: error-path undo — failed body still unbinds"
fi

# D. `as NAME` yields the DST path.
if grep -aqE "WITH_AS_NAME /wm_as" "$LOG"; then
    echo "[test_hamsh_with] OK: 'as NAME' binds the DST path for the body"
else
    echo "[test_hamsh_with] FAIL: 'as NAME' did not bind the DST path"; fail=1
fi

# survival
if ! grep -aqF "WITH_DONE" "$LOG"; then
    echo "[test_hamsh_with] FAIL: shell did not survive to WITH_DONE"; fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_hamsh_with] FAIL"
    exit 1
fi
echo "[test_hamsh_with] PASS"
