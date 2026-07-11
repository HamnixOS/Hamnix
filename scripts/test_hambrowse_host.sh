#!/usr/bin/env bash
# scripts/test_hambrowse_host.sh — FAST, QEMU-free gate for the hambrowse
# HTML engine (lib/htmlengine.ad) via the x86_64-linux host harness
# (user/hambrowse_host.ad).
#
# The native browser render gate (scripts/test_de_browser.sh) needs a full
# installer-image boot (~6 min). This gate compiles the SAME parse+layout+
# colour engine for the host Linux target and runs it directly on a local
# HTML fixture in milliseconds — so the engine can be regression-tested
# without QEMU. It asserts the layout summary, the wrapped-text FLOW, and
# the CSS-colour rung (style="color:" / <font color> / named + hex, with
# links staying link-blue).
#
# Builds with the frozen Python seed compiler (always compiles 100% of the
# tree; no self-host bootstrap needed) so this gate is dependency-light.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/hambrowse_host"
FIX="tests/fixtures/hambrowse_colors.html"
mkdir -p "$OUT"

echo "[hb-host] compiling engine for x86_64-linux ..."
if ! python3 -m compiler.adder compile --target=x86_64-linux \
        user/hambrowse_host.ad -o "$BIN" 2>"$OUT/compile.log"; then
    echo "[hb-host] FAIL: host harness did not compile"; cat "$OUT/compile.log"; exit 1
fi
echo "[hb-host] PASS host harness compiled -> $BIN"

# Confirm the NATIVE target still compiles from the same engine (no regress).
echo "[hb-host] compiling native hambrowse for x86_64-adder-user ..."
if ! python3 -m compiler.adder compile --target=x86_64-adder-user \
        user/hambrowse.ad -o "$OUT/hambrowse_native.elf" 2>"$OUT/native.log"; then
    echo "[hb-host] FAIL: native hambrowse did not compile"; cat "$OUT/native.log"; exit 1
fi
echo "[hb-host] PASS native hambrowse still compiles"

echo "[hb-host] running host harness on $FIX ..."
DUMP="$OUT/dump.txt"
if ! "$BIN" "$FIX" 600 >"$DUMP" 2>&1; then
    echo "[hb-host] FAIL: host harness exited non-zero"; cat "$DUMP"; exit 1
fi
cat "$DUMP"

fail=0
assert_grep() {
    local pat="$1" msg="$2"
    if grep -q -- "$pat" "$DUMP"; then
        echo "[hb-host] PASS $msg"
    else
        echo "[hb-host] FAIL $msg (missing: $pat)"; fail=1
    fi
}

# Layout produced content + a link.
if grep -Eq 'LAYOUT segs=[1-9][0-9]* rows=[1-9][0-9]* links=[1-9]' "$DUMP"; then
    echo "[hb-host] PASS layout produced segments/rows/links"
else
    echo "[hb-host] FAIL layout summary missing content"; fail=1
fi

# Wrapped-text FLOW reconstructs the page.
assert_grep 'FLOW  Green Heading' "flow shows the heading text"
assert_grep 'red span and' "flow shows inline coloured words in-line"

# CSS colour rung: each colour form resolves correctly.
assert_grep '#00aa00 b1 .*|Green Heading|'        "h1 style=color:#0a0 -> green (3-digit hex expanded)"
assert_grep '#ff0000 .*| red span|'               "span style=color:red -> #ff0000"
assert_grep '#0000ff .*| blue font|'              "font color=blue -> #0000ff"
assert_grep '#800080 .*|Whole purple'             "p style=color:#800080 -> purple"
assert_grep '#008080 .*|teal item|'               "font color=teal -> #008080"
assert_grep '#ffa500 .*| inside orange|'          "span style=color:orange -> #ffa500"

# Links keep their role colour even adjacent to a coloured span, and default
# text is body-black.
assert_grep '#1a4fd0 b0 u1 l0 | blue link|'       "link stays link-blue (#1a4fd0), underlined, link id 0"
assert_grep '#101010 .*|Plain body text'          "uncoloured text stays body-black (#101010)"

# bgcolor must NOT be mistaken for text color (word-boundary check): the
# text of the bgcolor paragraph must resolve to body-black, not yellow.
if grep -q '#ffff00 .*bgcolor is not' "$DUMP"; then
    echo "[hb-host] FAIL bgcolor was mistaken for text color"; fail=1
else
    echo "[hb-host] PASS bgcolor not mistaken for text color (word boundary)"
fi
assert_grep '#101010 .*|bgcolor is not text color.|' "bgcolor paragraph text stays body-black"

if [ "$fail" -eq 0 ]; then
    echo "[hb-host] RESULT: PASS"
    exit 0
else
    echo "[hb-host] RESULT: FAIL"
    exit 1
fi
