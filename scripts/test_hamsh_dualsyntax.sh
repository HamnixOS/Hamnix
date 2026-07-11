#!/usr/bin/env bash
# scripts/test_hamsh_dualsyntax.sh — hamsh DUAL block syntax + the
# Deliverable-2 ergonomics (HAMSH_SPEC §5, §8a).
#
# hamsh accepts TWO fully-interchangeable block syntaxes, chosen per
# block from the token that opens the body:
#   * brace   — `HEADER { statements }`      (interactive one-liner form)
#   * colon   — `HEADER:` + indented body     (Python-style, script form)
#               or an inline single-statement `HEADER: statement`.
# Both are legal in BOTH contexts (REPL + sourced file) and may mix.
#
# This gate proves, over the serial console (prompt-gated + output-
# adaptive via scripts/_hamsh_drive.sh):
#   A. brace one-liner runs its taken body / skips its untaken body
#   B. inline-colon one-liner runs taken / skips untaken
#   C. a MULTI-LINE indentation suite (if / for / def) executes — the
#      lexer's INDENT/DEDENT + the colon-suite parser, end to end, over
#      the Python-REPL continuation (blank line terminates)
#   D. the string builtins upper/lower/split/join/replace
#   E. a parse error reports a LINE NUMBER
#   F. sourcing an indentation SCRIPT FILE runs it (the primary use case)
#
# ABSENCE assertions use INLINE (single physical line) forms so the
# typed-input echo lands on a `hamsh$ ` prompt line that hamsh_ran
# (scripts/_hamsh_log.sh) filters out — a continuation `> ` line is NOT
# filtered, so untaken-branch markers are only ever typed on prompt
# lines. PRESENCE assertions for multi-line suites use a begin-of-line
# match (`^MARKER$`) — genuine `echo` output starts a fresh line, the
# editor's repainted continuation echo never does.
set -uo pipefail
trap '' PIPE

. "$(dirname "$0")/_build_lock.sh"
. "$(dirname "$0")/_hamsh_log.sh"

PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"
. "$PROJ_ROOT/scripts/_verdict.sh"
. "$PROJ_ROOT/scripts/_hamsh_drive.sh"

TAG=test_hamsh_dualsyntax
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

# --- A. brace one-liner (taken + untaken) ---------------------------
hamsh_send_await 'if 5 > 2 { echo DUAL_BRACE_YES }' 'DUAL_BRACE_YES' "$CMD_WAIT" || true
hamsh_send 'if 1 > 5 { echo DUAL_BRACE_NO }'
hamsh_send_await 'echo GATE_A' 'GATE_A' "$CMD_WAIT" || true

# --- B. inline-colon one-liner (taken + untaken) --------------------
hamsh_send_await 'if 5 > 2: echo DUAL_INLINE_YES' 'DUAL_INLINE_YES' "$CMD_WAIT" || true
hamsh_send 'if 1 > 5: echo DUAL_INLINE_NO'
hamsh_send_await 'echo GATE_B' 'GATE_B' "$CMD_WAIT" || true

# --- C. multi-line indentation suites (if / for / def) --------------
# Each top-level suite is terminated by a blank line (Python-REPL feel).
hamsh_send 'if 5 > 2:'
hamsh_send '    echo DUAL_MLIND_YES'
hamsh_send ''
hamsh_send_await 'echo GATE_C1' 'GATE_C1' "$CMD_WAIT" || true
hamsh_send 'for i in a b:'
hamsh_send '    echo DUAL_FOR_$i'
hamsh_send ''
hamsh_send_await 'echo GATE_C2' 'GATE_C2' "$CMD_WAIT" || true
hamsh_send 'def dgreet(who):'
hamsh_send '    echo DUAL_DEF_$who'
hamsh_send ''
hamsh_send_await 'dgreet(planet)' 'DUAL_DEF_planet' "$CMD_WAIT" || true

# --- D. string builtins ---------------------------------------------
hamsh_send_await 'echo up=${upper("abc")}' 'up=ABC' "$CMD_WAIT" || true
hamsh_send_await 'echo lo=${lower("XYZ")}' 'lo=xyz' "$CMD_WAIT" || true
hamsh_send_await 'echo sj=${join(split("p,q,r", ","), "+")}' 'sj=p+q+r' "$CMD_WAIT" || true
hamsh_send_await 'echo rp=${replace("a-b-c", "-", "_")}' 'rp=a_b_c' "$CMD_WAIT" || true

# --- E. parse error carries a line number ---------------------------
hamsh_send_await 'if 1 > 0 notablock' 'parse error [line' "$CMD_WAIT" || true

# --- F. source an INDENTATION script FILE ---------------------------
# Build it one line at a time; hamsh single quotes keep the leading
# spaces literal so the sourced file carries real indentation. (No '$'
# in the payload — sidesteps a nest of bash/hamsh quote escaping.)
hamsh_send "echo 'n = 4' > /tmp/dualsyntax.hamsh"
hamsh_send "echo 'if n > 3:' >> /tmp/dualsyntax.hamsh"
hamsh_send "echo '    echo FILE_DUAL_YES' >> /tmp/dualsyntax.hamsh"
hamsh_send "echo '    echo FILE_DUAL_Y2' >> /tmp/dualsyntax.hamsh"
hamsh_send "echo 'for k in x y:' >> /tmp/dualsyntax.hamsh"
hamsh_send "echo '    echo FILE_FOR_ITER' >> /tmp/dualsyntax.hamsh"
hamsh_send_await 'source /tmp/dualsyntax.hamsh' 'FILE_DUAL_Y2' "$CMD_WAIT" || true

hamsh_send_await 'echo GATE_DONE' 'GATE_DONE' "$CMD_WAIT" || true
hamsh_send 'exit'
sleep 2

# --- cleaned command-output view ------------------------------------
CLEAN=$(mktemp)
sed 's/\x1b\[[0-9;]*[A-Za-z]//g; s/\r/\n/g' "$LOG" > "$CLEAN"
# ran_bol MARKER — a genuine echo prints MARKER as a whole output line.
ran_bol() { grep -aqE "^$1\$" "$CLEAN"; }

verdict_boot_gate "$TAG" "$LOG" 0 'DUAL_BRACE_YES|GATE_A'
if ! hamsh_ran "$LOG" "DUAL_BRACE_YES" && ! hamsh_ran "$LOG" "GATE_A"; then
    verdict_inconclusive "$TAG" \
        "no early marker observed within ${CMD_WAIT}s — guest starved. Re-run quiet."
fi

fail=0

# A. brace taken / untaken
if hamsh_ran "$LOG" "DUAL_BRACE_YES"; then echo "[$TAG] OK: brace taken body ran"; else
    echo "[$TAG] WRONG: brace taken body did not run"; fail=1; fi
if hamsh_ran "$LOG" "DUAL_BRACE_NO"; then
    echo "[$TAG] WRONG: brace untaken body leaked"; fail=1; else
    echo "[$TAG] OK: brace untaken body skipped"; fi

# B. inline-colon taken / untaken
if hamsh_ran "$LOG" "DUAL_INLINE_YES"; then echo "[$TAG] OK: inline-colon taken body ran"; else
    echo "[$TAG] WRONG: inline-colon taken body did not run"; fail=1; fi
if hamsh_ran "$LOG" "DUAL_INLINE_NO"; then
    echo "[$TAG] WRONG: inline-colon untaken body leaked"; fail=1; else
    echo "[$TAG] OK: inline-colon untaken body skipped"; fi

# C. multi-line indentation suites
if ran_bol "DUAL_MLIND_YES"; then echo "[$TAG] OK: multi-line indentation if ran"; else
    echo "[$TAG] WRONG: multi-line indentation if did not run"; fail=1; fi
if ran_bol "DUAL_FOR_a" && ran_bol "DUAL_FOR_b"; then
    echo "[$TAG] OK: indentation for-loop iterated"; else
    echo "[$TAG] WRONG: indentation for-loop did not iterate"; fail=1; fi
if ran_bol "DUAL_DEF_planet"; then echo "[$TAG] OK: indentation def defined + called"; else
    echo "[$TAG] WRONG: indentation def did not run"; fail=1; fi

# D. string builtins
for pair in "up=ABC:upper" "lo=xyz:lower" "sj=p+q+r:split/join" "rp=a_b_c:replace"; do
    m="${pair%%:*}"; name="${pair##*:}"
    if hamsh_ran "$LOG" "$m"; then echo "[$TAG] OK: string builtin $name"; else
        echo "[$TAG] WRONG: string builtin $name (want '$m')"; fail=1; fi
done

# E. line-numbered parse error
if grep -aqF "parse error [line" "$LOG"; then echo "[$TAG] OK: parse error carries a line number"; else
    echo "[$TAG] WRONG: parse error had no line number"; fail=1; fi

# F. sourced indentation file (if body + 2-iteration for)
file_for_n=$(grep -acE "^FILE_FOR_ITER\$" "$CLEAN" || true)
if ran_bol "FILE_DUAL_YES" && ran_bol "FILE_DUAL_Y2" && [ "$file_for_n" -ge 2 ]; then
    echo "[$TAG] OK: sourced indentation script executed (for iterated $file_for_n times)"; else
    echo "[$TAG] WRONG: sourced indentation script did not fully execute (for_iters=$file_for_n)"; fail=1; fi

if ! hamsh_ran "$LOG" "GATE_DONE"; then
    echo "[$TAG] WRONG: shell did not survive to the end (GATE_DONE absent)"; fail=1; fi

rm -f "$CLEAN"
if [ "$fail" -ne 0 ]; then
    echo "[$TAG] --- command-output lines ---" >&2
    hamsh_outlines "$LOG" | tail -50 >&2
    verdict_fail "$TAG" "a dual-syntax / ergonomics assertion was VIOLATED"
fi
verdict_pass "$TAG" "brace + colon + multi-line indentation all execute; string builtins + line-numbered errors + sourced indentation file work"
