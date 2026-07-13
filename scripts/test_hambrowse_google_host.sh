#!/usr/bin/env bash
# scripts/test_hambrowse_google_host.sh — FAST, QEMU-free gate for the CORE
# google.com interaction in the native browser engine (lib/htmlengine.ad):
# a search form must (a) render its query box + submit button, (b) accept a
# typed query, and (c) SUBMIT to the form's action -> a results URL.
#
# Regression guard for the "you can load google.com but it's not usable" bug:
# _serialize_form dropped the form's `action`, so submitting the search box
# navigated to the current page's "?q=cats" instead of "/search?q=cats" (the
# results page). The fix prepends the action path; this gate asserts the
# NAV target is "/search?q=...", not a bare "?q=...".
#
# Builds with the frozen Python seed compiler for both the host harness
# (x86_64-linux) and the native browser (x86_64-adder-user), so a regression
# in either target fails here without a QEMU boot.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/hambrowse_host"
FIX="tests/fixtures/hambrowse_google.html"
mkdir -p "$OUT"

echo "[hb-google] compiling engine for x86_64-linux ..."
if ! python3 -m compiler.adder compile --target=x86_64-linux \
        user/hambrowse_host.ad -o "$BIN" 2>"$OUT/compile.log"; then
    echo "[hb-google] FAIL: host harness did not compile"; cat "$OUT/compile.log"; exit 1
fi
echo "[hb-google] PASS host harness compiled -> $BIN"

echo "[hb-google] compiling native hambrowse for x86_64-adder-user ..."
if ! python3 -m compiler.adder compile --target=x86_64-adder-user \
        user/hambrowse.ad -o "$OUT/hambrowse_native.elf" 2>"$OUT/native.log"; then
    echo "[hb-google] FAIL: native hambrowse did not compile"; cat "$OUT/native.log"; exit 1
fi
echo "[hb-google] PASS native hambrowse still compiles"

fail=0
assert_grep() {   # pattern file message
    if grep -Eq -- "$1" "$2"; then
        echo "[hb-google] PASS $3"
    else
        echo "[hb-google] FAIL $3 (missing: $1)"; fail=1
    fi
}
assert_nogrep() { # pattern file message
    if grep -Eq -- "$1" "$2"; then
        echo "[hb-google] FAIL $3 (present: $1)"; fail=1
    else
        echo "[hb-google] PASS $3"
    fi
}

# (a) The homepage renders: heading, the query box, and a submit button.
D0="$OUT/g_render.txt"
"$BIN" "$FIX" 880 >"$D0" 2>&1 || { echo "[hb-google] FAIL: render exited non-zero"; cat "$D0"; exit 1; }
cat "$D0"
assert_grep 'TITLE Google'                       "$D0" "title is Google"
assert_grep '\[cats_+\]'                          "$D0" "query box renders with its value"
assert_grep '\[ Google Search \]'                "$D0" "submit button renders"

# (b) Typing a query updates the box (oninput/DOM value flows to the render).
D1="$OUT/g_type.txt"
"$BIN" "$FIX" 880 setval q "plan 9 os" >"$D1" 2>&1
assert_grep '\[plan 9 os\]'                      "$D1" "typed query appears in the box"

# (c) THE FIX: submitting the search form navigates to the action's results
# URL (/search?q=...), carrying the query — NOT a bare "?q=..." on the
# homepage. This is what made google "unusable" before.
D2="$OUT/g_submit.txt"
"$BIN" "$FIX" 880 submit tsf >"$D2" 2>&1
cat "$D2" | grep -E 'SUBMIT|NAV' || true
assert_grep '^NAV /search\?q=cats'               "$D2" "submit navigates to /search?q=cats (action path prepended)"
assert_grep 'hl=en'                              "$D2" "hidden field carried into the results URL"
# Regression: the NAV must carry the action path, never a bare '?q='.
assert_nogrep '^NAV \?q='                        "$D2" "NAV is not a bare ?q= (action dropped) regression"

if [ "$fail" -ne 0 ]; then
    echo "[hb-google] RESULT: FAIL"; exit 1
fi
echo "[hb-google] RESULT: PASS"
