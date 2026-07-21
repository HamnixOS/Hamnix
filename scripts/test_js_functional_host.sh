#!/usr/bin/env bash
# scripts/test_js_functional_host.sh — FAST, QEMU-free FUNCTIONAL gate for
# hambrowse: does a page actually WORK (JS runs, the DOM mutates, event handlers
# fire), not merely RENDER. This is the functional counterpart to the pixel/SSIM
# fidelity harness — that one checks static painting; this one loads a page, runs
# its <script>, SIMULATES an event, and checks the RESULTING DOM.
#
# HOW IT DRIVES THE ENGINE (no QEMU, no browser window):
#   The x86_64-linux host build of the engine (user/hambrowse_host.ad) parses an
#   HTML file, runs its load-time <script>s (draining setTimeout(f,0) timers),
#   and dumps the layout. Post-load INTERACTION is driven by the harness verbs,
#   each of which fires a REAL event through the engine's bubbling dispatch core
#   (the SAME core a pointer click routes through) and re-dumps:
#       hambrowse_host FILE W click  ID          -> click ID  (fires click handlers)
#       hambrowse_host FILE W submit FORMID      -> submit FORMID (fires onsubmit)
#       hambrowse_host FILE W setval ID VALUE    -> set value + oninput/onchange
#   The dump carries: JSLOG <console.log line>, and FLOW/SEG (the RENDERED text) —
#   so a handler's DOM mutation is verified TWO ways: the console readback AND the
#   re-rendered page text (a mutation baked into the paint, not a glyph pixel).
#
# THE ORACLE: each interactive page has a HAND-SPECIFIED expected post-event DOM
# (documented per assertion below). Where chromium is installed the harness ALSO
# cross-checks the load-time DOM against `chromium --headless --dump-dom` (a real
# browser's post-load-JS serialized DOM) — but chromium is OPTIONAL so the gate
# stays deterministic on CI runners that lack it. (Headless --dump-dom does not
# run our synthetic clicks, so interactive cases use the hand-spec oracle.)
#
# Builds the host harness (x86_64-linux) AND the native browser
# (x86_64-adder-user) with the frozen seed compiler, so a regression in either
# target fails here with no QEMU boot.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/hambrowse_host"
PAGES="tests/jsfunc/pages"
mkdir -p "$OUT"

echo "[js-fn] compiling engine for x86_64-linux ..."
if ! python3 -m compiler.adder compile --target=x86_64-linux \
        user/hambrowse_host.ad -o "$BIN" 2>"$OUT/jsfn_compile.log"; then
    echo "[js-fn] FAIL: host harness did not compile"; cat "$OUT/jsfn_compile.log"; exit 1
fi
echo "[js-fn] PASS host harness compiled -> $BIN"

echo "[js-fn] compiling native hambrowse for x86_64-adder-user ..."
if ! python3 -m compiler.adder compile --target=x86_64-adder-user \
        user/hambrowse.ad -o "$OUT/hambrowse_native.elf" 2>"$OUT/jsfn_native.log"; then
    echo "[js-fn] FAIL: native hambrowse did not compile"; cat "$OUT/jsfn_native.log"; exit 1
fi
echo "[js-fn] PASS native hambrowse still compiles"

fail=0
D0=""            # output file of the CURRENT case

run() {          # run <page.html> [verb args...]  -> capture dump into $D0
    local page="$1"; shift
    D0="$OUT/jsfn_$(basename "$page" .html).txt"
    "$BIN" "$PAGES/$page" 880 "$@" >"$D0" 2>&1
}

assert_grep() {   # pattern message
    if grep -Eq -- "$1" "$D0"; then
        echo "[js-fn] PASS $2"
    else
        echo "[js-fn] FAIL $2 (missing: $1)"; fail=1
    fi
}
assert_nogrep() { # pattern message
    if grep -Eq -- "$1" "$D0"; then
        echo "[js-fn] FAIL $2 (present: $1)"; fail=1
    else
        echo "[js-fn] PASS $2"
    fi
}

# Optional chromium cross-check of the LOAD-time DOM (no interaction): the real
# browser's post-load-JS serialized DOM must contain <pattern>. Skipped (not a
# failure) when chromium is absent.
CHROMIUM="$(command -v chromium || command -v chromium-browser || true)"
chrome_load_has() {   # page.html regex message
    [ -n "$CHROMIUM" ] || { echo "[js-fn] SKIP chromium xref: $3 (no chromium)"; return; }
    local abs; abs="$(pwd)/$PAGES/$1"
    if "$CHROMIUM" --headless --dump-dom "file://$abs" 2>/dev/null | grep -Eq -- "$2"; then
        echo "[js-fn] PASS chromium xref: $3"
    else
        echo "[js-fn] FAIL chromium xref: $3 (missing in chrome dump: $2)"; fail=1
    fi
}

echo "----- (1) counter: addEventListener('click') + textContent update -----"
# Expected post-click DOM: #count text becomes 'C1'. Console: 'COUNTER now=1'.
run counter.html click inc
assert_grep '^JSLOG COUNTER now=1$'  "click handler fired, closure counter incremented"
assert_grep 'FLOW  *Count: C1'       "textContent setter mutated the rendered DOM (C1)"
assert_nogrep '^JSERR'               "no uncaught JS error"

echo "----- (2) toggle: classList.toggle + display:none hides in render -----"
# Expected post-click DOM: #panel gains class 'hidden' (display:none) -> its text
# is REMOVED from the rendered flow.
run toggle.html click btn
assert_grep '^JSLOG TOGGLE hidden=true$' "classList.toggle added 'hidden'"
# After the click dump, PANELTEXT must NOT appear (display:none hid it). The load
# dump (before CLICK) DOES show it; grep only lines AFTER the CLICK marker.
if sed -n '/^CLICK/,$p' "$D0" | grep -Eq 'PANELTEXT'; then
    echo "[js-fn] FAIL display:none did not hide the panel (PANELTEXT still rendered)"; fail=1
else
    echo "[js-fn] PASS display:none toggle removed the panel from the render"
fi
assert_nogrep '^JSERR'               "no uncaught JS error"

echo "----- (3) dombuild: createElement+appendChild build a <ul> from an array -----"
# Expected DOM: <ul> with three <li> (ITEM-Apple/Banana/Cherry). Console:
# 'DOMBUILD children=3' (created-element .children.length — the fixed bug).
run dombuild.html
assert_grep '^JSLOG DOMBUILD children=3$' "created <ul>.children.length == 3 (no null-deref)"
assert_grep 'FLOW  *-   ITEM-Apple'  "first built <li> rendered"
assert_grep 'FLOW  *-   ITEM-Cherry' "third built <li> rendered"
assert_nogrep '^JSERR'               "no uncaught JS error"
chrome_load_has dombuild.html '<li>ITEM-Banana</li>' "chrome built the same <li> list"

echo "----- (4) formvalidate: submit empty input -> validation node appended -----"
# Expected DOM: a <p>VALERR-required</p> appended to #msgs. Console:
# 'FORMVALIDATE empty msgs=1'.
run formvalidate.html submit form
assert_grep '^JSLOG FORMVALIDATE empty msgs=1$' "onsubmit(preventDefault) appended a validation node"
assert_grep 'VALERR-required'        "the validation message rendered"
assert_nogrep '^JSERR'               "no uncaught JS error"

echo "----- (5) tabs: event delegation + class swap shows the picked panel -----"
# Expected DOM: click Tab2 -> #p2 gains 'active' (shown), #p1 loses it (hidden).
# Console: 'TABS active=2 target=t2'.
run tabs.html click t2
assert_grep '^JSLOG TABS active=2 target=t2$' "delegated click read e.target + data-tab attr"
if sed -n '/^CLICK/,$p' "$D0" | grep -Eq 'PANELTWO'; then
    echo "[js-fn] PASS the selected panel (PANELTWO) is shown"
else
    echo "[js-fn] FAIL the selected panel did not become visible"; fail=1
fi
if sed -n '/^CLICK/,$p' "$D0" | grep -Eq 'PANELONE'; then
    echo "[js-fn] FAIL the previously-active panel (PANELONE) was not hidden"; fail=1
else
    echo "[js-fn] PASS the previously-active panel (PANELONE) is hidden"
fi
assert_nogrep '^JSERR'               "no uncaught JS error"

echo "----- (6) timer: setTimeout(f,0) updates a node after the load drain -----"
# Expected DOM: #msg text becomes 'TIMER-FIRED' (load-time timer drained).
run timer.html
assert_grep '^JSLOG TIMER scheduled$' "top-level ran"
assert_grep '^JSLOG TIMER done$'      "setTimeout callback ran (event-loop drain)"
assert_grep 'TIMER-FIRED'             "timer callback's DOM mutation rendered"
assert_nogrep 'PENDING'               "the placeholder text was replaced"
assert_nogrep '^JSERR'                "no uncaught JS error"

echo "----- (7) eventdelegation: click routes to the right child via e.target -----"
# Expected DOM: click #i2 -> that <li> text becomes 'PICKED', #status 'ROUTED-i2'.
run eventdelegation.html click i2
assert_grep '^JSLOG DELEGATE target=i2$' "container listener saw e.target == clicked child"
assert_grep 'FLOW  *-   PICKED'      "the clicked child's textContent mutated"
assert_grep 'ROUTED-i2'              "status derived from e.target.id rendered"
# the OTHER children are untouched
assert_grep 'FLOW  *-   One'         "sibling #i1 untouched"
assert_grep 'FLOW  *-   Three'       "sibling #i3 untouched"
assert_nogrep '^JSERR'               "no uncaught JS error"

if [ "$fail" -ne 0 ]; then
    echo "[js-fn] RESULT: FAIL"; exit 1
fi
echo "[js-fn] RESULT: PASS"
