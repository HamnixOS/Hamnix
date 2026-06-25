#!/usr/bin/env bash
# scripts/test_hamsh_tok_capacity.sh
#
# REGRESSION GATE: hamsh's whole-file source path must be able to tokenize
# the largest rc script it sources WITHOUT silently truncating.
#
# THE BUG THIS GUARDS (fixed 2026-06-25)
# --------------------------------------
# The rc/init path (_run_rc_path in user/hamsh.ad) reads an ENTIRE
# multi-line script into a 16 KiB buffer and lexes it in ONE pass via
# lex_line(). The lexer emits tokens into fixed-size tok_* arrays of
# capacity TOK_MAX, and _emit_tok() used to SILENTLY drop any token past
# TOK_MAX. etc/rc.d/rc.5 (runlevel 5 / graphical hook) lexes to ~600
# tokens (one TK_NEWLINE per line + every word/op/redirect/brace), which
# overran the old TOK_MAX=512. The dropped tail included rc.5's closing
# `}` and the trailing TK_EOF, so parse_program ran into zeroed token
# slots mid-block and aborted the WHOLE script with a spurious
# `hamsh: parse error: empty command`. Consequence: the scene-DE
# clients (panel/desktop/terminal/file-manager/calc/editor) launched
# from rc.5 never ran -> blank desktop.
#
# THE INVARIANT
# -------------
# TOK_MAX must comfortably exceed the lexer token count of the largest
# sourced script. We approximate rc.5's lexer token count here and
# assert TOK_MAX leaves real headroom. _emit_tok also now raises a clean
# "token-limit exceeded" lexical error instead of truncating, so even a
# future overrun fails LOUDLY rather than silently — this test asserts
# that diagnostic exists too.
#
# This is a static source check (no kernel boot): cheap, fast, and it
# pins the exact numeric headroom that the heavyweight rl5 DE boot test
# (scripts/test_installer_de_runlevel5.sh) proves end-to-end.

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

HAMSH=user/hamsh.ad
RC5=etc/rc.d/rc.5

fail() { echo "[test_tok_capacity] FAIL: $*" >&2; exit 1; }

[ -f "$HAMSH" ] || fail "$HAMSH missing"
[ -f "$RC5" ]   || fail "$RC5 missing"

# --- read TOK_MAX from the source -------------------------------------
TOK_MAX=$(grep -E '^TOK_MAX:[[:space:]]*uint64[[:space:]]*=' "$HAMSH" \
            | head -1 | sed -E 's/.*=[[:space:]]*([0-9]+).*/\1/')
[ -n "$TOK_MAX" ] || fail "could not read TOK_MAX from $HAMSH"
echo "[test_tok_capacity] TOK_MAX = $TOK_MAX"

# --- the tok_* arrays must be sized to match TOK_MAX ------------------
# A TOK_MAX larger than the backing arrays would write out of bounds.
for arr in tok_kind tok_str tok_int tok_save_kind tok_save_str tok_save_int; do
    SZ=$(grep -E "^${arr}:[[:space:]]*Array\[" "$HAMSH" \
            | head -1 | sed -E 's/.*Array\[[[:space:]]*([0-9]+).*/\1/')
    [ -n "$SZ" ] || fail "could not read array size for $arr"
    [ "$SZ" -ge "$TOK_MAX" ] || \
        fail "$arr capacity $SZ < TOK_MAX $TOK_MAX (out-of-bounds risk)"
done
echo "[test_tok_capacity] PASS: all tok_* arrays >= TOK_MAX"

# --- approximate rc.5's lexer token count -----------------------------
# Mirror lex_line()'s tokenization rules closely enough to get a sound
# lower bound: skip whitespace + '#' comments to EOL; '\n'/';' -> one
# TK_NEWLINE; a single-quoted/double-quoted run -> one token; structural
# operators ({ } = > < | &) -> one token each; any other non-space run
# -> one word token. +1 for the trailing TK_EOF.
RC5_TOKS=$(python3 - "$RC5" <<'PY'
import sys
data = open(sys.argv[1], 'rb').read()
n = len(data); p = 0; toks = 0
SPACE = (32, 9, 13)
STRUCT = set(b"{}=><|&")
while p < n:
    c = data[p]
    if c in SPACE:
        p += 1; continue
    if c == 35:                      # '#' comment to EOL
        while p < n and data[p] != 10:
            p += 1
        continue
    if c == 10 or c == 59:           # '\n' / ';'
        toks += 1; p += 1; continue
    if c in (39, 34):                # quoted string -> one token
        q = c; p += 1
        while p < n and data[p] != q:
            p += 1
        p += 1; toks += 1; continue
    if c in STRUCT:                  # structural op -> one token
        toks += 1; p += 1; continue
    while p < n and data[p] not in SPACE and data[p] not in STRUCT \
            and data[p] not in (10, 59, 35) and data[p] not in (39, 34):
        p += 1
    toks += 1
print(toks + 1)                      # + trailing TK_EOF
PY
)
echo "[test_tok_capacity] rc.5 approx lexer tokens = $RC5_TOKS"

# Require real headroom: TOK_MAX must be at least 1.5x the approximate
# rc.5 token count. (rc.5 lexes to ~500-600 tokens; 4096 leaves >6x.)
NEED=$(( RC5_TOKS * 3 / 2 ))
[ "$TOK_MAX" -ge "$NEED" ] || \
    fail "TOK_MAX $TOK_MAX < 1.5x rc.5 tokens ($NEED); rc.5 would silently truncate"
echo "[test_tok_capacity] PASS: TOK_MAX leaves >=1.5x headroom over rc.5 ($TOK_MAX >= $NEED)"

# --- the loud-overflow diagnostic must exist --------------------------
grep -q 'token-limit exceeded' "$HAMSH" || \
    fail "lexer no longer reports 'token-limit exceeded' (silent truncation could return)"
grep -Eq 'tok_count >= TOK_MAX' "$HAMSH" || \
    fail "_emit_tok overflow guard missing"
# the overflow guard must set lex_error, not just early-return.
if ! awk '/def _emit_tok/{f=1} f&&/lex_error = 1/{print "ok"; exit} /^def /&&!/_emit_tok/{f=0}' \
        "$HAMSH" | grep -q ok; then
    fail "_emit_tok overflow path does not set lex_error (would truncate silently)"
fi
echo "[test_tok_capacity] PASS: overflow raises a clean lexical error"

echo "[test_tok_capacity] PASS"
