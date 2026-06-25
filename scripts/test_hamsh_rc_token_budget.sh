#!/usr/bin/env bash
# scripts/test_hamsh_rc_token_budget.sh
#
# REGRESSION GUARD for the rc.5 DE-autostart bug: hamsh lexes a whole
# sourced rc file as ONE buffer into fixed tok_* arrays sized TOK_MAX.
# When _emit_tok silently DROPPED tokens past the cap, an oversized rc
# script parsed from a truncated token stream and aborted (the parser
# saw a half-statement and reported a misleading "empty command"), so
# the entire script — including the DE launches in /etc/rc.d/rc.5 —
# never ran.
#
# The lexer now fails LOUDLY on overflow (run_source: "token-limit
# exceeded"), but a too-large rc file would still refuse to source. This
# static guard keeps every shipped rc/source-on-boot script comfortably
# under TOK_MAX so they always parse whole.
#
# It approximates hamsh's tokenizer: comments and blank lines emit no
# tokens; everything else is split on whitespace and the shell operator
# characters, and string/word runs count as one token each (a close
# enough upper-bound estimate). FAIL if any script exceeds WARN_FRAC of
# TOK_MAX.

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

# Read TOK_MAX from the hamsh source so this tracks the real cap.
TOK_MAX="$(grep -E '^TOK_MAX:' user/hamsh.ad | sed -E 's/.*=[[:space:]]*([0-9]+).*/\1/')"
[ -n "$TOK_MAX" ] || { echo "[rc_token_budget] FAIL: could not read TOK_MAX from user/hamsh.ad"; exit 1; }
echo "[rc_token_budget] hamsh TOK_MAX = $TOK_MAX"

# Scripts that hamsh sources WHOLE on boot (one lex buffer each).
FILES=(etc/rc.boot etc/rc.boot.full etc/rc.d/rc.0 etc/rc.d/rc.3 etc/rc.d/rc.5 etc/rc.d/rc.6)

# Fail if a script uses more than this fraction of the cap (headroom for
# the tokenizer-estimate being approximate + future small edits).
WARN_FRAC_NUM=80   # 80%
fail=0
for f in "${FILES[@]}"; do
    [ -f "$f" ] || continue
    toks="$(python3 - "$f" <<'PY'
import sys,re
n=0
for line in open(sys.argv[1],encoding='utf-8',errors='replace'):
    s=line.strip()
    if not s or s.startswith('#'):
        continue
    # Strip trailing comments (best-effort; rc files rarely inline #).
    # Split on whitespace and shell operator glyphs; each run is a token.
    # Also count each operator char as its own token.
    parts=re.findall(r"[^\s|&;<>(){}]+|[|&;<>(){}]", s)
    n+=len(parts)+1  # +1 ~ implicit statement/EOL token
print(n)
PY
)"
    limit=$(( TOK_MAX * WARN_FRAC_NUM / 100 ))
    if [ "$toks" -gt "$limit" ]; then
        echo "[rc_token_budget] FAIL: $f ~$toks tokens > ${WARN_FRAC_NUM}% of TOK_MAX ($limit). Split the script or raise TOK_MAX."
        fail=1
    else
        echo "[rc_token_budget] OK:   $f ~$toks tokens (<= $limit)"
    fi
done

if [ "$fail" -ne 0 ]; then
    echo "[rc_token_budget] FAIL: a boot rc script is near/over the hamsh token cap."
    exit 1
fi
echo "[rc_token_budget] PASS: all boot rc scripts fit comfortably under TOK_MAX."
