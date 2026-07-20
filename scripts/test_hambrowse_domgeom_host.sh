#!/usr/bin/env bash
# scripts/test_hambrowse_domgeom_host.sh — FAST, QEMU-free INTEGRATION gate that
# ties the DOM geometry + traversal surface together in one fixture (browser W3C
# campaign). Prior rounds landed the pieces separately (gates `matches`, `qsa`,
# `domcore`, `geom`, `domgeom2`); this gate proves they cooperate on one page:
#   (1) Element.matches(selector)  — class / compound / id / negative.
#   (2) Element.closest(selector)  — walks self-or-ancestor to a #id / .class,
#       the ubiquitous event-delegation helper (e.target.closest('.item')).
#   (3) document.body / documentElement / head resolve to the real <body>/<html>/
#       <head> element nodes (spec-uppercase tagName).
#   (4) getBoundingClientRect()/offsetWidth/Height/clientWidth/Height read the
#       laid-out box: a 9-char block ("Rectangle") is pinned to width 72 (9*CELL_W)
#       x height 16 (LINE_H), with x/y cross-checked against the SEG display dump.
#
# Builds the host harness (x86_64-linux) AND the native browser
# (x86_64-adder-user) with the frozen seed compiler, so a regression in either
# target fails here with no QEMU boot. Exact-output oracle on console.log lines.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/hambrowse_host"
FIX="tests/fixtures/hambrowse_domgeom.html"
mkdir -p "$OUT"

echo "[hb-domgeom] compiling engine for x86_64-linux ..."
if ! python3 -m compiler.adder compile --target=x86_64-linux \
        user/hambrowse_host.ad -o "$BIN" 2>"$OUT/domgeom_compile.log"; then
    echo "[hb-domgeom] FAIL: host harness did not compile"; cat "$OUT/domgeom_compile.log"; exit 1
fi
echo "[hb-domgeom] PASS host harness compiled -> $BIN"

echo "[hb-domgeom] compiling native hambrowse for x86_64-adder-user ..."
if ! python3 -m compiler.adder compile --target=x86_64-adder-user \
        user/hambrowse.ad -o "$OUT/hambrowse_native.elf" 2>"$OUT/domgeom_native.log"; then
    echo "[hb-domgeom] FAIL: native hambrowse did not compile"; cat "$OUT/domgeom_native.log"; exit 1
fi
echo "[hb-domgeom] PASS native hambrowse still compiles"

fail=0
D0="$OUT/domgeom_run.txt"
"$BIN" "$FIX" 880 >"$D0" 2>&1 || { echo "[hb-domgeom] FAIL: render exited non-zero"; cat "$D0"; exit 1; }

grep -E 'JSLOG|JSERR' "$D0" || true

assert_grep() {   # pattern message
    if grep -Eq -- "$1" "$D0"; then
        echo "[hb-domgeom] PASS $2"
    else
        echo "[hb-domgeom] FAIL $2 (missing: $1)"; fail=1
    fi
}
assert_nogrep() { # pattern message
    if grep -Eq -- "$1" "$D0"; then
        echo "[hb-domgeom] FAIL $2 (present: $1)"; fail=1
    else
        echo "[hb-domgeom] PASS $2"
    fi
}

# ---- document roots ------------------------------------------------------
assert_grep '^JSLOG roots HTML BODY HEAD$' \
    "document.documentElement/body/head resolve to <html>/<body>/<head>"

# ---- Element.matches() ---------------------------------------------------
assert_grep '^JSLOG m1 true$'  "matches('.widget') class -> true"
assert_grep '^JSLOG m2 true$'  "matches('div.widget') compound -> true"
assert_grep '^JSLOG m3 true$'  "matches('#box') id -> true"
assert_grep '^JSLOG m4 false$' "matches('.item') negative -> false"
assert_grep '^JSLOG m5 true$'  "matches('.item.selected') compound class -> true"

# ---- Element.closest() ---------------------------------------------------
assert_grep '^JSLOG c1 app$'   "closest('#app') finds far ancestor by id"
assert_grep '^JSLOG c2 panel$' "closest('.panel') finds ancestor by class"
assert_grep '^JSLOG c3 true$'  "closest('.nope') returns null on no match"
assert_grep '^JSLOG c4 first$' "alink.closest('.item') walks up to the enclosing li"

# ---- getBoundingClientRect()/offset*/client* pinned to the laid-out box --
# "Rectangle" == 9 chars -> 9*CELL_W(8)=72 wide, LINE_H=16 tall.
assert_grep '^JSLOG wh 72 16$'  "getBoundingClientRect() width==72 height==16"
assert_grep '^JSLOG off 72 16$' "offsetWidth==72 offsetHeight==16"
assert_grep '^JSLOG cli 72 16$' "clientWidth==72 clientHeight==16"
assert_grep '^JSLOG edge true true true true$' \
    "left/top mirror x/y; right/bottom == x+w / y+h"

# ---- x/y cross-checked against the SEG display dump ----------------------
SEGLINE=$(grep -E 'SEG [0-9]+ [0-9]+ .*\|Rectangle\|' "$D0" | head -1)
if [ -z "$SEGLINE" ]; then
    echo "[hb-domgeom] FAIL: no SEG line for |Rectangle| to cross-check against"; fail=1
else
    SROW=$(echo "$SEGLINE" | awk '{print $2}')
    SX=$(echo "$SEGLINE"   | awk '{print $3}')
    EXP_TOP=$(( SROW * 16 ))
    assert_grep "^JSLOG xy ${SX} ${EXP_TOP} ${SX} ${EXP_TOP}\$" \
        "getBoundingClientRect() x/y (and offsetLeft/Top) match the SEG-dump box"
fi

# ---- no uncaught error ---------------------------------------------------
assert_nogrep '^JSERR'   "no uncaught JS error across the domgeom script"
assert_nogrep 'Uncaught' "no 'Uncaught' from a missing geometry/traversal API"

if [ "$fail" -ne 0 ]; then
    echo "[hb-domgeom] RESULT: FAIL"; exit 1
fi
echo "[hb-domgeom] RESULT: PASS"
