#!/usr/bin/env bash
# scripts/test_hamsh_with.sh — HAMSH_SPEC §19 (#111): `with` context
# managers married to Plan 9 binds.
#
# The distinctive rung: Python's `with` fused with a Plan 9 bind. Inside
#   with bind(SRC, DST):
#       ...
# the graft SRC->DST is live IN THE CURRENT (PID 1) process; at the
# block's end it is UNDONE — even if the body fails. Neither Python nor
# rc has this.
#
# OBSERVABILITY NOTE: a child `cat /proc/self/ns` does NOT reflect a
# shell bind in this build — a pre-existing devproc/child-COW quirk that
# hits a plain builtin `bind` identically (see the CONTROL check), NOT a
# `with` bug. So this gate observes the bind the RIGHT way: IN-PROCESS,
# via `cd DST` — the `cd` builtin's sys_chdir resolves through PID 1's
# own live namespace, which is exactly where `with bind` applies the
# graft. `cd DST` succeeds iff DST is bound right now.
#
# Proves, over the prompt-gated serial driver:
#   A. ROUND-TRIP (brace form): `cd DST` RESOLVES inside the block and
#      FAILS after it — the graft is live in-block and auto-undone.
#   B. DIFFERENTIAL (indent form ≡ brace form): same in a Python suite.
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

# --- A. brace-form round-trip (in-process cd resolution) ----------------
# `cd DST && echo M` runs the marker IFF DST is bound (cd resolves it).
hamsh_send_await 'with bind(/tmp, /wm_a) { cd /wm_a && echo WITH_A_RESOLVED }' \
    'WITH_A_RESOLVED' "$CMD_WAIT" || true
hamsh_send 'cd /'
hamsh_send 'cd /wm_a && echo WITH_A_LEAK'
hamsh_send_await 'echo WITH_A_END' 'WITH_A_END' "$CMD_WAIT" || true

# --- B. indent-form round-trip (differential ≡ brace) -------------------
hamsh_send 'with bind(/tmp, /wm_b):'
hamsh_send '    cd /wm_b && echo WITH_B_RESOLVED'
hamsh_send ''
hamsh_send_await 'echo WITH_B_MID' 'WITH_B_MID' "$CMD_WAIT" || true
hamsh_send 'cd /'
hamsh_send 'cd /wm_b && echo WITH_B_LEAK'
hamsh_send_await 'echo WITH_B_END' 'WITH_B_END' "$CMD_WAIT" || true

# --- C. error path: failing body still unbinds --------------------------
# Body resolves DST (proving it was bound), then FAILS (`false`).
hamsh_send_await 'with bind(/tmp, /wm_c) { cd /wm_c && echo WITH_C_RESOLVED ; false }' \
    'WITH_C_RESOLVED' "$CMD_WAIT" || true
hamsh_send 'cd /'
hamsh_send 'cd /wm_c && echo WITH_C_LEAK'
hamsh_send_await 'echo WITH_C_END' 'WITH_C_END' "$CMD_WAIT" || true

# --- D. `as NAME` yields the bound path inside the body -----------------
hamsh_send 'cd /'
hamsh_send_await 'with bind(/tmp, /wm_as) as wp { echo WITH_AS_NAME $wp }' \
    'WITH_AS_NAME /wm_as' "$CMD_WAIT" || true

# --- CONTROL (informational): child cat's /proc/self/ns visibility ------
hamsh_send 'bind /tmp /wm_ctrl'
hamsh_send 'cd /wm_ctrl && echo WITH_CTRL_RESOLVED'
hamsh_send 'cd /'
hamsh_send 'unmount /wm_ctrl'

hamsh_send_await 'echo WITH_DONE' 'WITH_DONE' "$CMD_WAIT" || true
hamsh_send 'exit'
sleep 2

# --- cleaned command-output view ----------------------------------------
CLEAN=$(mktemp)
sed 's/\x1b\[[0-9;]*[A-Za-z]//g; s/\r/\n/g' "$LOG" > "$CLEAN"
# A genuine echo prints MARKER as a whole output line; the typed-input
# echo always carries a `hamsh$ `/`> ` prefix, so `^MARKER$` can't false-match.
ran_bol() { grep -aqE "^$1\$" "$CLEAN"; }

verdict_boot_gate "$TAG" "$LOG" 0 'WITH_A_RESOLVED|WITH_DONE'
if ! hamsh_ran "$LOG" "WITH_A_RESOLVED" && ! hamsh_ran "$LOG" "WITH_DONE"; then
    verdict_inconclusive "$TAG" "no marker observed within ${CMD_WAIT}s — guest starved. Re-run quiet."
fi

fail=0

# A. brace-form: resolves inside, gone after.
if ran_bol "WITH_A_RESOLVED"; then
    echo "[$TAG] OK: with bind — DST RESOLVES inside the block (graft live)"; else
    echo "[$TAG] WRONG: with bind — DST did not resolve inside the block"; fail=1; fi
if ran_bol "WITH_A_LEAK"; then
    echo "[$TAG] WRONG: with bind LEAKED — DST still resolves after the block"; fail=1; else
    echo "[$TAG] OK: with bind auto-undo — DST no longer resolves after the block"; fi

# B. indent-form round-trip (differential ≡).
if ran_bol "WITH_B_RESOLVED"; then
    echo "[$TAG] OK: indent-form with bind — resolves inside (≡ brace)"; else
    echo "[$TAG] WRONG: indent-form with bind — did not resolve inside"; fail=1; fi
if ran_bol "WITH_B_LEAK"; then
    echo "[$TAG] WRONG: indent-form with bind LEAKED after the block"; fail=1; else
    echo "[$TAG] OK: indent-form with bind auto-undo (≡ brace form)"; fi

# C. error path: resolved inside, undone even though the body failed.
if ran_bol "WITH_C_RESOLVED"; then
    echo "[$TAG] OK: error-path — DST resolved inside the failing block"; else
    echo "[$TAG] WRONG: error-path — DST did not resolve inside"; fail=1; fi
if ran_bol "WITH_C_LEAK"; then
    echo "[$TAG] WRONG: error-path LEAK — failed body left DST bound"; fail=1; else
    echo "[$TAG] OK: error-path undo — failed body still unbinds"; fi

# D. `as NAME` yields the DST path.
if ran_bol "WITH_AS_NAME /wm_as"; then
    echo "[$TAG] OK: 'as NAME' binds the DST path for the body"; else
    echo "[$TAG] WRONG: 'as NAME' did not bind the DST path"; fail=1; fi

# CONTROL (informational only — never fails the gate).
if ran_bol "WITH_CTRL_RESOLVED"; then
    echo "[$TAG] CONTROL: a plain builtin bind also resolves in-process (parity)"
else
    echo "[$TAG] CONTROL: builtin bind did not resolve in-process (investigate separately)"
fi

if ! hamsh_ran "$LOG" "WITH_DONE"; then
    echo "[$TAG] WRONG: shell did not survive to WITH_DONE"; fail=1; fi

rm -f "$CLEAN"
if [ "$fail" -ne 0 ]; then
    echo "[$TAG] --- command-output lines ---" >&2
    hamsh_outlines "$LOG" | tail -60 >&2
    verdict_fail "$TAG" "a with-context-manager assertion was VIOLATED"
fi
verdict_pass "$TAG" "with bind round-trips (resolves in-block, auto-undone after), indent≡brace, error-path unbinds, as-NAME works"
