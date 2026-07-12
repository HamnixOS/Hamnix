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
# Ground truth = `cat /proc/self/ns` (a bound DST appears as a line).
# This gate proves, over the prompt-gated serial driver (robust to a slow
# boot under load, unlike a fixed `sleep N`):
#   A. ROUND-TRIP (brace form): DST is bound INSIDE the block and GONE
#      after it — auto-undo on the normal-exit path.
#   B. DIFFERENTIAL (indent form ≡ brace form): the SAME `with` in a
#      Python-indent suite round-trips identically.
#   C. ERROR PATH: a `with bind(...)` whose body FAILS still unbinds.
#   D. `as NAME` binds the DST path for the body to name.
set -uo pipefail
trap '' PIPE

. "$(dirname "$0")/_build_lock.sh"
. "$(dirname "$0")/_hamsh_log.sh"

PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"
. "$PROJ_ROOT/scripts/_verdict.sh"
. "$PROJ_ROOT/scripts/_hamsh_drive.sh"

TAG=test_hamsh_with
ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf
BOOT_WAIT="${BOOT_WAIT:-420}"
CMD_WAIT="${CMD_WAIT:-240}"

bash scripts/build_user.sh >/dev/null || verdict_inconclusive "$TAG" "build_user failed"
INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py >/dev/null \
    || verdict_inconclusive "$TAG" "build_initramfs failed"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal init/main.ad -o "$ELF" >/dev/null \
    || verdict_inconclusive "$TAG" "kernel compile failed"

LOG=$(mktemp)
cleanup() {
    hamsh_shutdown
    INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1
    [ "${KEEP_LOGS:-0}" = "1" ] || rm -f "$LOG"
}
trap cleanup EXIT

hamsh_boot "$LOG" "$ELF"
hamsh_wait_boot "[hamsh:stage-07] loop-enter" "$BOOT_WAIT" \
    || verdict_inconclusive "$TAG" "hamsh never reached its prompt in ${BOOT_WAIT}s (host-starved?)"
hamsh_sync 120 \
    || verdict_inconclusive "$TAG" "readline never echoed FEEDER_SYNC — stdin not consumed"

# --- A. brace-form round-trip -------------------------------------------
hamsh_send_await 'echo WITH_A_IN' 'WITH_A_IN' "$CMD_WAIT" || true
# The inside `cat /proc/self/ns` prints /wm_brace IFF the bind is live in
# the block — awaiting that literal proves "bound inside".
hamsh_send_await 'with bind(/tmp, /wm_brace) { cat /proc/self/ns }' '/wm_brace' "$CMD_WAIT" || true
hamsh_send_await 'echo WITH_A_OUT' 'WITH_A_OUT' "$CMD_WAIT" || true
hamsh_send 'cat /proc/self/ns'
hamsh_send_await 'echo WITH_A_END' 'WITH_A_END' "$CMD_WAIT" || true

# --- B. indent-form round-trip (differential ≡ brace) -------------------
hamsh_send_await 'echo WITH_B_IN' 'WITH_B_IN' "$CMD_WAIT" || true
hamsh_send 'with bind(/tmp, /wm_indent):'
hamsh_send '    cat /proc/self/ns'
hamsh_send ''
hamsh_send_await 'echo WITH_B_OUT' 'WITH_B_OUT' "$CMD_WAIT" || true
hamsh_send 'cat /proc/self/ns'
hamsh_send_await 'echo WITH_B_END' 'WITH_B_END' "$CMD_WAIT" || true

# --- C. error path: failing body still unbinds --------------------------
hamsh_send_await 'echo WITH_C_IN' 'WITH_C_IN' "$CMD_WAIT" || true
hamsh_send 'with bind(/tmp, /wm_err) { false }'
hamsh_send 'cat /proc/self/ns'
hamsh_send_await 'echo WITH_C_END' 'WITH_C_END' "$CMD_WAIT" || true

# --- D. `as NAME` yields the bound path inside the body -----------------
hamsh_send_await 'with bind(/tmp, /wm_as) as wp { echo WITH_AS_NAME $wp }' \
    'WITH_AS_NAME /wm_as' "$CMD_WAIT" || true

hamsh_send_await 'echo WITH_DONE' 'WITH_DONE' "$CMD_WAIT" || true
hamsh_send 'exit'
sleep 2

# --- cleaned command-output view ----------------------------------------
CLEAN=$(mktemp)
sed 's/\x1b\[[0-9;]*[A-Za-z]//g; s/\r/\n/g' "$LOG" > "$CLEAN"

verdict_boot_gate "$TAG" "$LOG" 0 'WITH_A_IN|WITH_DONE'
if ! hamsh_ran "$LOG" "WITH_A_IN" && ! hamsh_ran "$LOG" "WITH_DONE"; then
    verdict_inconclusive "$TAG" "no marker observed within ${CMD_WAIT}s — guest starved. Re-run quiet."
fi

# Region slices (on the ANSI-stripped view).
a_inside=$(sed -n '/^WITH_A_IN$/,/^WITH_A_OUT$/p' "$CLEAN")
a_after=$(sed -n '/^WITH_A_OUT$/,/^WITH_A_END$/p' "$CLEAN")
b_inside=$(sed -n '/^WITH_B_IN$/,/^WITH_B_OUT$/p' "$CLEAN")
b_after=$(sed -n '/^WITH_B_OUT$/,/^WITH_B_END$/p' "$CLEAN")
c_after=$(sed -n '/^WITH_C_IN$/,/^WITH_C_END$/p' "$CLEAN")

fail=0

# A `bind /from /to` line in the /proc/self/ns dump proves the graft is
# live in the Pgrp — anchored `^bind ` so the TYPED command echo
# (`hamsh$ with bind(/tmp, /wm_brace) …`) can never false-match.
ns_has() { echo "$1" | grep -qE "^bind .*$2"; }

# A. brace-form: bound inside, gone after.
if ns_has "$a_inside" "/wm_brace"; then
    echo "[$TAG] OK: with bind — DST bound INSIDE the block"; else
    echo "[$TAG] WRONG: with bind — DST not bound inside the block"; fail=1; fi
if ns_has "$a_after" "/wm_brace"; then
    echo "[$TAG] WRONG: with bind LEAKED — DST still bound after the block"; fail=1; else
    echo "[$TAG] OK: with bind auto-undo — DST gone after the block"; fi

# B. indent-form round-trip (differential ≡).
if ns_has "$b_inside" "/wm_indent"; then
    echo "[$TAG] OK: indent-form with bind — bound inside (≡ brace)"; else
    echo "[$TAG] WRONG: indent-form with bind — not bound inside"; fail=1; fi
if ns_has "$b_after" "/wm_indent"; then
    echo "[$TAG] WRONG: indent-form with bind LEAKED after the block"; fail=1; else
    echo "[$TAG] OK: indent-form with bind auto-undo (≡ brace form)"; fi

# C. error path: undone even though the body failed.
if ns_has "$c_after" "/wm_err"; then
    echo "[$TAG] WRONG: error-path LEAK — failed body left DST bound"; fail=1; else
    echo "[$TAG] OK: error-path undo — failed body still unbinds"; fi

# D. `as NAME` yields the DST path.
if grep -aqE "^WITH_AS_NAME /wm_as$" "$CLEAN"; then
    echo "[$TAG] OK: 'as NAME' binds the DST path for the body"; else
    echo "[$TAG] WRONG: 'as NAME' did not bind the DST path"; fail=1; fi

if ! hamsh_ran "$LOG" "WITH_DONE"; then
    echo "[$TAG] WRONG: shell did not survive to WITH_DONE"; fail=1; fi

rm -f "$CLEAN"
if [ "$fail" -ne 0 ]; then
    echo "[$TAG] --- command-output lines ---" >&2
    hamsh_outlines "$LOG" | tail -60 >&2
    verdict_fail "$TAG" "a with-context-manager assertion was VIOLATED"
fi
verdict_pass "$TAG" "with bind round-trips (bound inside, auto-undo after), indent≡brace, error-path unbinds, as-NAME works"
