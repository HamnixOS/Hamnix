#!/usr/bin/env bash
# scripts/test_hambrowse_realsite_host.sh — FAST, QEMU-free gate that runs the
# ACTUAL bytes real sites serve (captured under tests/fixtures/realsites/) through
# the native browser engine (lib/htmlengine.ad + lib/jsengine.ad).
#
# WHY: prior browser rounds were verified against hand-written synthetic
# fixtures. A user drove the shipped browser to google.com, typed a query, hit
# search, and got a "JS error (see script)" — because the REAL page exercises JS
# constructs / DOM APIs the synthetic fixtures never did (eval, navigator, giant
# machine-generated inline scripts, etc.). This gate locks in real-site compat:
#
#   (a) the engine never crashes on real HTML (a huge eval'd google script used
#       to segfault by overrunning the token/AST arenas),
#   (b) `eval` and `navigator` are defined (real sites feature-detect on them;
#       a missing global is a ReferenceError that aborts the whole script),
#   (c) real google.com's search box renders as a FIELD (shaded surface) and the
#       native type+submit chain navigates to /search?...q=..., i.e. the exact
#       flow the user exercises, and
#   (d) common sites (example.com, wikipedia) render real content.
#
# Deterministic: it runs the CAPTURED HTML, never the live network.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/hambrowse_host"
FX="tests/fixtures/realsites"
mkdir -p "$OUT"

echo "[hb-real] compiling engine for x86_64-linux ..."
if ! python3 -m compiler.adder compile --target=x86_64-linux \
        user/hambrowse_host.ad -o "$BIN" 2>"$OUT/real_compile.log"; then
    echo "[hb-real] FAIL: host harness did not compile"; cat "$OUT/real_compile.log"; exit 1
fi
echo "[hb-real] PASS host harness compiled -> $BIN"

# The native hambrowse must also still compile (it shares the engine).
if ! python3 -m compiler.adder compile --target=x86_64-adder-user \
        user/hambrowse.ad -o "$OUT/hambrowse_native.elf" 2>"$OUT/real_native.log"; then
    echo "[hb-real] FAIL: native hambrowse did not compile"; cat "$OUT/real_native.log"; exit 1
fi
echo "[hb-real] PASS native hambrowse still compiles"

fail=0
assert_grep()   { if grep -Eq -- "$1" "$2"; then echo "[hb-real] PASS $3"; else echo "[hb-real] FAIL $3 (missing: $1)"; fail=1; fi; }
assert_nogrep() { if grep -Eq -- "$1" "$2"; then echo "[hb-real] FAIL $3 (present: $1)"; else echo "[hb-real] PASS $3"; fi; }

run_ok() {  # fixture width [extra args...] -> writes $OUT/real_<name>.txt, asserts rc==0
    local name="$1"; shift
    local page="$1"; shift
    "$BIN" "$page" "$@" >"$OUT/real_${name}.txt" 2>&1
    local rc=$?
    if [ "$rc" -eq 0 ]; then
        echo "[hb-real] PASS ${name}: engine ran without crashing (rc=0)"
    else
        echo "[hb-real] FAIL ${name}: engine exited rc=$rc (crash/segfault on real HTML)"; fail=1
    fi
}

# ---- (a) no crash on any captured real page --------------------------------
run_ok google_home "$FX/google_home.html" 980
run_ok google_search "$FX/google_search.html" 980
run_ok example "$FX/example.html" 980
run_ok wikipedia "$FX/wikipedia_plan9.html" 980

# ---- (b) eval + navigator are defined (feature-detection globals) -----------
# A missing global surfaces as "X is not defined" in the JSLOG stream; these
# must NOT appear (they used to abort real scripts wholesale).
for n in google_home google_search wikipedia; do
    assert_nogrep 'navigator is not defined' "$OUT/real_${n}.txt" "${n}: navigator is defined (no ReferenceError)"
    assert_nogrep 'eval is not defined'      "$OUT/real_${n}.txt" "${n}: eval is defined (no ReferenceError)"
done

# Prove eval + navigator actually work (not just stubbed to silence the error).
cat > "$OUT/real_probe.html" <<'HTML'
<html><head><title>probe</title></head><body><p id="r">x</p><script>
var ok = (eval('40+2')===42) && (typeof navigator!=='undefined') &&
         navigator.userAgent.indexOf('Hamnix')>=0;
document.getElementById('r').textContent = ok ? 'PROBE-OK' : 'PROBE-BAD';
</script></body></html>
HTML
"$BIN" "$OUT/real_probe.html" 880 >"$OUT/real_probe.txt" 2>&1
assert_grep 'PROBE-OK'   "$OUT/real_probe.txt" "eval() computes and navigator.userAgent reads (real behaviour, not a stub)"
assert_nogrep 'PROBE-BAD' "$OUT/real_probe.txt" "eval/navigator probe did not fall to the BAD branch"

# ---- (c) THE USER FLOW on REAL google.com HTML -----------------------------
# The real homepage identifies its query control by name="q" inside
# <form action="/search" name="f">. Render must classify it as a text field,
# resolve the form, and the native type+submit must navigate to /search?...q=...
GT="$OUT/real_google_fieldnav.txt"
"$BIN" "$FX/google_home.html" 980 fieldnav q "test" >"$GT" 2>&1
grep -E 'FIELDNAV' "$GT" || true
assert_grep '^FIELDNAV id=q idx=[0-9]+ textfield=1' "$GT" \
    "real google.com query box classifies as a text field"
assert_grep '^FIELDNAV form=[0-9]+' "$GT" \
    "real google.com query field resolves its enclosing <form action=/search>"
assert_grep '^FIELDNAV NAV /search\?.*q=test' "$GT" \
    "typing 'test' + submit navigates to /search?...q=test on REAL google HTML"

# The search box paints as a FIELD, not raw ASCII: its segment carries a
# non-empty background surface (seg_bg), i.e. it reads as an input box.
assert_grep '^SEG [0-9]+ [0-9]+ #[0-9a-f]+ b0 u0 s0 l-1 bg#[0-9a-f]+ \|\[_+\]\|' \
    "$OUT/real_google_home.txt" "the search field renders on a shaded field surface (looks like a box, not ASCII)"

# ---- (d) common sites render actual content --------------------------------
assert_grep 'Example Domain'        "$OUT/real_example.txt"   "example.com renders its heading text"
assert_grep 'Plan 9'                "$OUT/real_wikipedia.txt" "wikipedia article renders its real body text"

if [ "$fail" -ne 0 ]; then
    echo "[hb-real] RESULT: FAIL"; exit 1
fi
echo "[hb-real] RESULT: PASS"
