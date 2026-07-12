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
hamsh_send_await 'dgreet("planet")' 'DUAL_DEF_planet' "$CMD_WAIT" || true

# --- D. string builtins ---------------------------------------------
# Emit each result as a bare `${ … }` word (no `prefix${ … }` — that
# tickles a PRE-EXISTING ND_ARGCAT/render_buf re-entrancy quirk, tracked
# separately, unrelated to the dual-syntax work). ran_bol matches the
# whole output line so a typed-input echo can never false-green.
hamsh_send_await 'echo ${upper("abc")}' 'ABC' "$CMD_WAIT" || true
hamsh_send_await 'echo ${lower("XYZ")}' 'xyz' "$CMD_WAIT" || true
hamsh_send_await 'echo ${join(split("p,q,r", ","), "+")}' 'p+q+r' "$CMD_WAIT" || true
hamsh_send_await 'echo ${replace("a-b-c", "-", "_")}' 'a_b_c' "$CMD_WAIT" || true
hamsh_send 'sv = strip("  ZQX  ")'
hamsh_send_await 'echo $sv' 'ZQX' "$CMD_WAIT" || true

# --- E. parse error carries a line number ---------------------------
hamsh_send_await 'if 1 > 0 notablock' 'parse error [line' "$CMD_WAIT" || true

# --- F. source an INDENTATION script FILE (the primary use case) ----
# Write the whole indented script in ONE command — a double-quoted echo
# whose `\n` escapes become real newlines and whose leading spaces are
# literal, so the file carries genuine significant indentation. One send
# is robust (no multi-append quote-drop window); no '$' in the body so
# nothing interpolates before `source` runs it.
hamsh_send 'echo "n = 4\nif n > 3:\n    echo FILE_DUAL_YES\n    echo FILE_DUAL_Y2\nfor k in x y:\n    echo FILE_FOR_ITER\n" > /tmp/dualsyntax.hamsh'
hamsh_send_await 'source /tmp/dualsyntax.hamsh' 'FILE_DUAL_Y2' "$CMD_WAIT" || true

# --- G. brace BLOCK in a SOURCED FILE (accept-either, file mode) ----
# Section F proved indentation-in-a-file; this proves the OTHER style —
# curly braces — is equally legal when a FILE is sourced (not just
# interactively). Together with A (brace interactive) + C (indent
# interactive) + F (indent file) this closes the full accept-either
# matrix: EITHER block syntax works in EITHER context.
hamsh_send 'echo "if 7 > 3 { echo BRACE_FILE_YES }\nfor k in x y { echo BRACE_FILE_ITER }\n" > /tmp/bracesyntax.hamsh'
hamsh_send_await 'source /tmp/bracesyntax.hamsh' 'BRACE_FILE_YES' "$CMD_WAIT" || true

# --- H. membership operators: `in` / `not in` -----------------------
# List element, negated list, string substring, and dict-key membership.
# Taken branches use the inline-colon one-liner so a false marker can
# only ever be typed on a filtered prompt line (see the header note).
hamsh_send_await 'if 2 in [1, 2, 3]: echo MEMB_LIST_YES' 'MEMB_LIST_YES' "$CMD_WAIT" || true
hamsh_send 'if 9 in [1, 2, 3]: echo MEMB_LIST_NO'
hamsh_send_await 'if 9 not in [1, 2, 3]: echo MEMB_NOTIN_YES' 'MEMB_NOTIN_YES' "$CMD_WAIT" || true
hamsh_send_await 'if "mn" in "hamnix": echo MEMB_SUBSTR_YES' 'MEMB_SUBSTR_YES' "$CMD_WAIT" || true
hamsh_send 'if "zz" in "hamnix": echo MEMB_SUBSTR_NO'
hamsh_send_await 'if "b" in {"a": 1, "b": 2}: echo MEMB_DICTKEY_YES' 'MEMB_DICTKEY_YES' "$CMD_WAIT" || true

# --- I. new string methods: find / count / startswith / endswith ----
# Each result feeds a comparison so the taken branch prints a distinct
# whole-line marker (never a bare integer that could false-match).
hamsh_send_await 'if find("hello", "ll") == 2: echo FIND_OK' 'FIND_OK' "$CMD_WAIT" || true
hamsh_send_await 'if count("banana", "a") == 3: echo COUNT_OK' 'COUNT_OK' "$CMD_WAIT" || true
hamsh_send_await 'if startswith("hamnix", "ham"): echo STARTS_OK' 'STARTS_OK' "$CMD_WAIT" || true
hamsh_send_await 'if endswith("run.hamsh", ".hamsh"): echo ENDS_OK' 'ENDS_OK' "$CMD_WAIT" || true

# --- J. DIFFERENTIAL: the SAME loop in brace vs indent style ---------
# Both styles must produce IDENTICAL output — the core "accept-either,
# same meaning" guarantee. Brace one-liner form first:
hamsh_send_await 'for i in a b { echo DIFF_FOR_$i }' 'DIFF_FOR_b' "$CMD_WAIT" || true
# ...then the byte-for-byte-equivalent indentation form:
hamsh_send 'for i in a b:'
hamsh_send '    echo DIFF_FOR_$i'
hamsh_send ''
hamsh_send_await 'echo GATE_DIFF' 'GATE_DIFF' "$CMD_WAIT" || true

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

# D. string builtins (each emitted as a whole output line)
for pair in "ABC|upper" "xyz|lower" "p+q+r|split/join" "a_b_c|replace" "ZQX|strip"; do
    m="${pair%%|*}"; name="${pair##*|}"
    if ran_bol "$(printf '%s' "$m" | sed 's/[.[*+]/\\&/g')"; then
        echo "[$TAG] OK: string builtin $name"; else
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

# G. sourced BRACE file (accept-either symmetry, file mode)
brace_file_n=$(grep -acE "^BRACE_FILE_ITER\$" "$CLEAN" || true)
if ran_bol "BRACE_FILE_YES" && [ "$brace_file_n" -ge 2 ]; then
    echo "[$TAG] OK: sourced BRACE script executed (for iterated $brace_file_n times)"; else
    echo "[$TAG] WRONG: sourced brace script did not fully execute (iters=$brace_file_n)"; fail=1; fi

# H. membership operators (in / not in): list, string, dict; + absence
for pair in "MEMB_LIST_YES|list-in" "MEMB_NOTIN_YES|list-not-in" \
            "MEMB_SUBSTR_YES|str-substr" "MEMB_DICTKEY_YES|dict-key"; do
    m="${pair%%|*}"; name="${pair##*|}"
    if ran_bol "$m"; then echo "[$TAG] OK: membership $name"; else
        echo "[$TAG] WRONG: membership $name did not run"; fail=1; fi
done
if hamsh_ran "$LOG" "MEMB_LIST_NO"; then
    echo "[$TAG] WRONG: membership list untaken body leaked"; fail=1; else
    echo "[$TAG] OK: membership list untaken body skipped"; fi
if hamsh_ran "$LOG" "MEMB_SUBSTR_NO"; then
    echo "[$TAG] WRONG: membership substr untaken body leaked"; fail=1; else
    echo "[$TAG] OK: membership substr untaken body skipped"; fi

# I. new string methods
for pair in "FIND_OK|find" "COUNT_OK|count" "STARTS_OK|startswith" "ENDS_OK|endswith"; do
    m="${pair%%|*}"; name="${pair##*|}"
    if ran_bol "$m"; then echo "[$TAG] OK: string method $name"; else
        echo "[$TAG] WRONG: string method $name did not run"; fail=1; fi
done

# J. DIFFERENTIAL both-styles-≡: the brace loop AND the indent loop each
# emit DIFF_FOR_a + DIFF_FOR_b, so a correct pair yields >=2 of each.
diff_a=$(grep -acE "^DIFF_FOR_a\$" "$CLEAN" || true)
diff_b=$(grep -acE "^DIFF_FOR_b\$" "$CLEAN" || true)
if [ "$diff_a" -ge 2 ] && [ "$diff_b" -ge 2 ]; then
    echo "[$TAG] OK: brace loop ≡ indent loop (DIFF_FOR_a=$diff_a DIFF_FOR_b=$diff_b)"; else
    echo "[$TAG] WRONG: brace/indent loops not equivalent (a=$diff_a b=$diff_b, want >=2 each)"; fail=1; fi
if ! hamsh_ran "$LOG" "GATE_DIFF"; then
    echo "[$TAG] WRONG: shell did not survive the differential section"; fail=1; fi

if ! hamsh_ran "$LOG" "GATE_DONE"; then
    echo "[$TAG] WRONG: shell did not survive to the end (GATE_DONE absent)"; fail=1; fi

rm -f "$CLEAN"
if [ "$fail" -ne 0 ]; then
    echo "[$TAG] --- command-output lines ---" >&2
    hamsh_outlines "$LOG" | tail -50 >&2
    verdict_fail "$TAG" "a dual-syntax / ergonomics assertion was VIOLATED"
fi
verdict_pass "$TAG" "brace + colon + multi-line indentation all execute; string builtins + line-numbered errors + sourced indentation file work"
