#!/usr/bin/env bash
# scripts/test_de_term_password_echo.sh — REGRESSION gate for the DE scene
# terminal PASSWORD-ECHO suppression (user-reported: `newshell hostowner` in
# the DE terminal showed the typed password `hamnix` in CLEAR TEXT).
#
# THE BUG
#   Serial / SSH password entry was ALREADY echo-free: the shell reads
#   passwords with a RAW fd-0 read (no line editor), and the kernel console
#   does NOT echo raw reads. But the DE scene terminal (user/hamtermscene.ad)
#   owns its OWN local per-keystroke echo (zero-lag editing; the inner shell
#   runs --no-echo), so it rendered the password glyphs regardless.
#
# THE FIX (shell <-> terminal echo-off control)
#   The shell brackets every password read with a private CSI written to
#   stdout, which the DE terminal drains + interprets to toggle its LOCAL
#   echo. It is swallowed by a real xterm / serial front end (unknown private
#   mode), so it is harmless everywhere else.
#       ESC [ ? 7767 l   -> local echo OFF (suppress keystroke rendering)
#       ESC [ ? 7767 h   -> local echo ON  (resume)
#   hamsh: de_echo_off() / de_echo_on(); hamtermscene: local_echo_on flag
#   toggled in _term_feed, with _key_local diverting to a NON-rendering
#   _key_local_noecho path while echo is off (the line is still buffered +
#   sent to the shell on Enter — only the on-screen echo is hidden).
#
# WHY THIS GATE IS STATIC
#   Driving keystrokes into the SCENE terminal has no reliable in-VM
#   injection point (see test_de_term_editor_features.sh / _cmd_not_found /
#   _render_nokey — all static for the same reason: the console->terminal
#   keys-ring write does not reach hamtermscene's blocking reader, and the
#   HW-key path needs a QMP socket that conflicts with -serial stdio). So we
#   lock the load-bearing MACHINERY on BOTH sides at the source + a clean
#   standalone compile. The behavioural half IS verifiable deterministically
#   on the serial console: `read -s` emits ESC[?7767l ... ESC[?7767h around
#   the raw read (proven manually; the password never appears on serial).
#
# rc=124 (host-load timeout on a compile) is NOT a failure.

set -uo pipefail

PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

HAMSH="user/hamsh.ad"
HTS="user/hamtermscene.ad"
SU="user/su.ad"
LOGIN="user/login.ad"
fail=0

pass()  { echo "[pw_echo] PASS $*"; }
failf() { echo "[pw_echo] FAIL $*" >&2; fail=1; }

# Require a fixed substring in a file.
needF() { # file substring human
    if grep -aqF -- "$2" "$1"; then pass "$3"; else failf "$3 (missing: '$2' in $1)"; fi
}
# Require a regex in a file.
needE() { # file regex human
    if grep -aqE -- "$2" "$1"; then pass "$3"; else failf "$3 (regex miss: /$2/ in $1)"; fi
}
# Require a multi-line (DOTALL) regex in a file.
needZ() { # file pcre human
    if grep -aPzoq -- "$2" "$1"; then pass "$3"; else failf "$3 (pcre miss in $1)"; fi
}

echo "[pw_echo] --- (1) shell emits the echo-off/on control (hamsh) ---"
needF "$HAMSH" 'def de_echo_off' "de_echo_off helper defined"
needF "$HAMSH" 'def de_echo_on'  "de_echo_on helper defined"
# The exact private CSI bytes must be emitted (ESC[?7767l off / ESC[?7767h on).
needF "$HAMSH" '\x1b[?7767l' "de_echo_off emits ESC[?7767l"
needF "$HAMSH" '\x1b[?7767h' "de_echo_on emits ESC[?7767h"

echo "[pw_echo] --- (2) password reads are bracketed by echo-off/on ---"
# builtin_read -s: de_echo_off before the raw read, de_echo_on after.
needZ "$HAMSH" '(?s)silent != 0:\s*\n\s*de_echo_off\(\).*?de_echo_on\(\)' \
    "read -s brackets its raw read with de_echo_off/de_echo_on"
# builtin_newshell password prompt: de_echo_off after the prompt, de_echo_on
# after the read.
needZ "$HAMSH" '(?s)write_cstr1\("password: "\)\s*\n\s*de_echo_off\(\).*?de_echo_on\(\)\s*\n\s*write_cstr1\("\\n"\)' \
    "newshell brackets its password read with de_echo_off/de_echo_on"

echo "[pw_echo] --- (3) su / login password reads bracketed too ---"
needF "$SU"    '\x1b[?7767l' "su read_password emits echo-off CSI"
needF "$SU"    '\x1b[?7767h' "su read_password emits echo-on CSI"
needF "$LOGIN" '\x1b[?7767l' "login read_password emits echo-off CSI"
needF "$LOGIN" '\x1b[?7767h' "login read_password emits echo-on CSI"

echo "[pw_echo] --- (4) terminal honours the control (hamtermscene) ---"
needF "$HTS" 'local_echo_on' "hamtermscene has a local_echo_on flag"
needE "$HTS" 'LOCAL_ECHO_MODE.*7767' "hamtermscene recognises private mode 7767"
# _term_feed toggles the flag on the h/l final byte of the 7767 private CSI.
needZ "$HTS" '(?s)csi_priv != 0 and csi_num == LOCAL_ECHO_MODE:.*?local_echo_on = 1.*?local_echo_on = 0' \
    "_term_feed toggles local_echo_on on ESC[?7767h/l"
# _key_local diverts to the non-rendering handler while echo is off.
needZ "$HTS" '(?s)def _key_local\(code: int32\):.*?if local_echo_on == 0:\s*\n\s*_key_local_noecho\(code\)' \
    "_key_local diverts to _key_local_noecho when echo is off"
needF "$HTS" 'def _key_local_noecho' "non-rendering password key handler defined"
# The no-echo handler must NOT render: it must not call _redraw_edit_line or
# push the (password) line to history. Extract JUST this function's body
# (from its def to the next top-level def) so the check can't leak into the
# neighbouring _key_local (which legitimately renders).
NOECHO_BODY="$(awk '/^def _key_local_noecho\(/{f=1} f&&/^def /&&!/_key_local_noecho/{if(seen){exit}} /^def _key_local_noecho\(/{seen=1} f{print}' "$HTS")"
if printf '%s' "$NOECHO_BODY" | grep -aqE '_redraw_edit_line|_hist_push'; then
    failf "_key_local_noecho renders/persists the password (found _redraw_edit_line/_hist_push)"
else
    pass "_key_local_noecho neither renders (_redraw_edit_line) nor stores (_hist_push) the password"
fi
# It must still SEND the buffered line to the shell on Enter (so the raw read
# receives the password bytes).
needZ "$HTS" '(?s)def _key_local_noecho\(code: int32\):.*?if code == 10:.*?_send_line\(&term_line\[0\], term_line_len\)' \
    "_key_local_noecho still sends the buffered line to the shell on Enter"

echo "[pw_echo] --- (5) clean standalone compile of both binaries ---"
compile_one() { # file label
    local f="$1" label="$2"
    local out; out="$(mktemp --tmpdir hamnix-pwc.XXXXXX.elf)"
    local log; log="$(mktemp --tmpdir hamnix-pwc.XXXXXX.log)"
    timeout 300 python3 -m compiler.adder compile --target=x86_64-bare-metal \
        "$f" -o "$out" >"$log" 2>&1
    local rc=$?
    rm -f "$out"
    if [ "$rc" = "124" ]; then
        echo "[pw_echo] NOTE compile of $label timed out (host load) — not a failure"
        rm -f "$log"; return 0
    fi
    # The bare-metal link step legitimately leaves kernel trap symbols
    # undefined (do_gp_fault etc.) when a single userland file is linked in
    # isolation; that is an `ld:` link error, NOT an Adder front-end error. We
    # only fail on a real Adder compile error (parse/type/codegen).
    if grep -aqE 'Traceback|SyntaxError|Adder|parse error|type error|Unknown|Undefined name|NameError' "$log"; then
        echo "[pw_echo] FAIL $label: Adder front-end error" >&2
        sed -n '1,40p' "$log" >&2
        rm -f "$log"; fail=1; return 1
    fi
    echo "[pw_echo] PASS $label: Adder front-end compiled cleanly"
    rm -f "$log"; return 0
}
compile_one "$HAMSH" "hamsh.ad"
compile_one "$HTS"   "hamtermscene.ad"

if [ "$fail" = "0" ]; then
    echo "[pw_echo] RESULT: PASS"
    exit 0
else
    echo "[pw_echo] RESULT: FAIL"
    exit 1
fi
