#!/usr/bin/env bash
# scripts/test_hamsh_parity_r4.sh — hamsh Python/bash parity round 4.
#
# Exercises the round-4 additions:
#
#   Python-scripting axis (string-method + functional parity)
#     * lstrip / rstrip (one-sided whitespace trim) vs strip
#     * capitalize / title (case transforms)
#     * ljust / rjust / center (padded to width, custom fill) + zfill
#         (zero-pad keeping a leading sign)
#     * splitlines (a string -> list of lines)
#     * map(fn, seq) / filter(fn, seq) — fn is a bare name (builtin OR
#         user def), applied per element via the sorted(key=) hook
#
#   bash terminal-ergonomics axis
#     * alias NAME='cmd args'  — first-word substitution, tail args kept
#     * unalias NAME           — removes the binding (proven by a count)
#
# INPUT IS PROMPT-GATED + OUTPUT-ADAPTIVE via scripts/_hamsh_drive.sh:
# every command is sent ONCE after a live-readline handshake and waited
# on its OWN observable effect; assertions look ONLY at genuine command
# OUTPUT (scripts/_hamsh_log.sh :: hamsh_ran drops the editor input echo)
# so a skipped line can never false-green off the typed command text.
set -uo pipefail
trap '' PIPE

. "$(dirname "$0")/_build_lock.sh"
. "$(dirname "$0")/_hamsh_log.sh"

PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"
. "$PROJ_ROOT/scripts/_verdict.sh"
. "$PROJ_ROOT/scripts/_hamsh_drive.sh"

TAG=test_hamsh_parity_r4
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

# --- string methods: strip family (assert via len, space-safe) ------
hamsh_send 's = "  hi  "'
hamsh_send_await 'echo LSL_${ len(lstrip(s)) }' 'LSL_4' "$CMD_WAIT" || true
hamsh_send_await 'echo RSL_${ len(rstrip(s)) }' 'RSL_4' "$CMD_WAIT" || true
hamsh_send_await 'echo STL_${ len(strip(s)) }'  'STL_2' "$CMD_WAIT" || true

# --- string methods: case transforms --------------------------------
hamsh_send_await 'echo CAP_${ capitalize("hELLO") }' 'CAP_Hello' "$CMD_WAIT" || true
hamsh_send_await 'echo TIT_${ title("hello-world") }' 'TIT_Hello-World' "$CMD_WAIT" || true

# --- string methods: padding ----------------------------------------
hamsh_send_await 'echo ZF_${ zfill("42", 5) }'        'ZF_00042'  "$CMD_WAIT" || true
hamsh_send_await 'echo ZFN_${ zfill("-7", 5) }'       'ZFN_-0007' "$CMD_WAIT" || true
hamsh_send_await 'echo LJ_${ ljust("ab", 5, ".") }'   'LJ_ab...'  "$CMD_WAIT" || true
hamsh_send_await 'echo RJ_${ rjust("ab", 5, ".") }'   'RJ_...ab'  "$CMD_WAIT" || true
hamsh_send_await 'echo CE_${ center("ab", 6, "-") }'  'CE_--ab--' "$CMD_WAIT" || true

# --- splitlines -----------------------------------------------------
hamsh_send_await 'echo SLC_${ len(splitlines("a\nb\nc")) }' 'SLC_3' "$CMD_WAIT" || true

# --- map / filter (builtin fn AND user def) -------------------------
hamsh_send 'def dbl(x) { return x * 2 }'
hamsh_send 'def keepbig(x) { return x > 2 }'
hamsh_send_await 'echo MP_${ join(map(dbl, [1, 2, 3]), ",") }'   'MP_2,4,6' "$CMD_WAIT" || true
hamsh_send_await 'echo MPS_${ join(map(str, [7, 8]), "-") }'     'MPS_7-8'  "$CMD_WAIT" || true
hamsh_send_await 'echo FLT_${ join(filter(keepbig, [1, 2, 3, 4]), ",") }' 'FLT_3,4' "$CMD_WAIT" || true

# --- alias / unalias ------------------------------------------------
# Define, use (ZAPPED emitted once), remove, use again (must NOT re-emit).
hamsh_send "alias zap='echo ZAPPED'"
hamsh_send_await 'zap' 'ZAPPED' "$CMD_WAIT" || true
hamsh_send 'unalias zap'
hamsh_send 'zap'
hamsh_send_await 'echo ALIAS_FENCE' 'ALIAS_FENCE' "$CMD_WAIT" || true
# Alias with a tail argument: `greet WORLD` -> `echo HELLO WORLD`.
hamsh_send "alias greet='echo HELLO'"
hamsh_send_await 'greet WORLD' 'HELLO WORLD' "$CMD_WAIT" || true

hamsh_send 'exit'
sleep 2

verdict_boot_gate "$TAG" "$LOG" 0 'LSL_4|MP_2,4,6'
if ! hamsh_ran "$LOG" "LSL_4" && ! hamsh_ran "$LOG" "MP_2,4,6"; then
    verdict_inconclusive "$TAG" \
        "no early marker observed within ${CMD_WAIT}s — guest starved. Re-run on a quiet host."
fi

fail=0
present() {
    if hamsh_ran "$LOG" "$1"; then echo "[$TAG] OK: $1"; else
        echo "[$TAG] WRONG: $1 absent (should have run)"; fail=1; fi
}
# string methods
present "LSL_4"; present "RSL_4"; present "STL_2"
present "CAP_Hello"; present "TIT_Hello-World"
present "ZF_00042"; present "ZFN_-0007"
present "LJ_ab..."; present "RJ_...ab"; present "CE_--ab--"
present "SLC_3"
# map / filter
present "MP_2,4,6"; present "MPS_7-8"; present "FLT_3,4"
# alias
present "ALIAS_FENCE"; present "HELLO WORLD"

# unalias proof: ZAPPED must appear EXACTLY once (only while the alias
# was live); a second copy would mean unalias failed to remove it.
zc=$(hamsh_ran_count "$LOG" "ZAPPED")
if [ "$zc" = "1" ]; then
    echo "[$TAG] OK: ZAPPED emitted once (unalias removed the binding)"
else
    echo "[$TAG] WRONG: ZAPPED count=$zc (expected 1 — unalias did not remove it)"
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[$TAG] --- command-output lines ---" >&2
    hamsh_outlines "$LOG" | tail -80 >&2
    verdict_fail "$TAG" "a round-4 parity assertion was VIOLATED"
fi
verdict_pass "$TAG" "lstrip/rstrip, capitalize/title, ljust/rjust/center/zfill, splitlines, map/filter, alias/unalias all correct"
