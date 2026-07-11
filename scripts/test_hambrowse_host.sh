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
assert_grep '#1a4fd0 b0 u1 l0 bg- | blue link|'   "link stays link-blue (#1a4fd0), underlined, link id 0"
assert_grep '#101010 .*|Plain body text'          "uncoloured text stays body-black (#101010)"

# Background-colour rung: bgcolor / background-color fill the box BEHIND the
# text (seg bg field) without changing the TEXT colour.
#   * bgcolor="yellow" paragraph: text body-black, bg #ffff00.
#   * <span style="background-color:#ffff00"> highlight: text body-black, bg yellow.
assert_grep '#101010 b0 u0 l-1 bg#ffff00 |bgcolor is not text color.|' \
    "p bgcolor=yellow -> body-black text on yellow bg"
assert_grep '#101010 b0 u0 l-1 bg#ffff00 | highlight|' \
    "span background-color:#ffff00 -> body-black text on yellow bg"
# The TEXT-colour field (immediately after 'SEG row x ') must never be yellow:
# that would mean bgcolor leaked into the text colour (word-boundary failure).
if grep -Eq '^SEG [0-9]+ [0-9]+ #ffff00' "$DUMP"; then
    echo "[hb-host] FAIL bgcolor was mistaken for text color"; fail=1
else
    echo "[hb-host] PASS bgcolor not mistaken for text color (word boundary)"
fi

# ====================================================================
# BOX-MODEL fixture — <hr>, <blockquote> indent, <h4>-<h6>.
# ====================================================================
FIX2="tests/fixtures/hambrowse_boxmodel.html"
DUMP2="$OUT/dump_boxmodel.txt"
echo "[hb-host] running host harness on $FIX2 ..."
if ! "$BIN" "$FIX2" 600 >"$DUMP2" 2>&1; then
    echo "[hb-host] FAIL: box-model harness exited non-zero"; cat "$DUMP2"; exit 1
fi
cat "$DUMP2"

assert_grep2() {
    local pat="$1" msg="$2"
    if grep -Eq -- "$pat" "$DUMP2"; then
        echo "[hb-host] PASS $msg"
    else
        echo "[hb-host] FAIL $msg (missing: $pat)"; fail=1
    fi
}

# <h1> still lays a heading rule (type 1); <hr> lays a distinct type-2 rule.
assert_grep2 '^RULE row 0 type 1$'      "h1 emits a heading rule (type 1)"
assert_grep2 '^RULE row [0-9]+ type 2$' "hr emits a full-width rule (type 2)"
# The <hr> row must be otherwise empty (no segment sits on the rule's row).
hr_row=$(grep -E '^RULE row [0-9]+ type 2$' "$DUMP2" | head -1 | awk '{print $3}')
if [ -n "$hr_row" ] && grep -Eq "^SEG $hr_row " "$DUMP2"; then
    echo "[hb-host] FAIL hr rule row $hr_row is not empty"; fail=1
else
    echo "[hb-host] PASS hr rule sits on its own empty row (row $hr_row)"
fi
# <blockquote> content is indented from the body left margin (x 8 -> 32).
assert_grep2 '^SEG [0-9]+ 32 .*Quoted text that is indented' \
    "blockquote indents content to x=32"
# Text before/after the blockquote stays at the x=8 body margin.
assert_grep2 '^SEG [0-9]+ 8 .*Back to the left margin' \
    "post-blockquote text returns to the x=8 margin"
# <h4>/<h5>/<h6> render as dark-blue bold headings, with NO rule row.
assert_grep2 '^SEG [0-9]+ 8 #14306e b1 .*Sub sub heading'  "h4 -> dark-blue bold heading"
assert_grep2 '^SEG [0-9]+ 8 #14306e b1 .*Smaller heading'  "h5 -> dark-blue bold heading"
assert_grep2 '^SEG [0-9]+ 8 #14306e b1 .*Smallest heading' "h6 -> dark-blue bold heading"

# <img> alt-text placeholder rung: alt text rendered as inline "[alt]" that
# flows with surrounding text; a bare <img> (no alt) shows "[img]".
assert_grep2 'Logo here: \[Hamnix logo\] and text after\.' \
    "img alt='Hamnix logo' -> inline [Hamnix logo] placeholder in flow"
assert_grep2 'Bare image: \[img\] ends\.' \
    "bare img (no alt) -> inline [img] placeholder in flow"

# ====================================================================
# TABLE fixture — two-pass column layout (measure widest cell per column,
# then place), <th> bold, per-cell colour + background.
# ====================================================================
FIX3="tests/fixtures/hambrowse_table.html"
DUMP3="$OUT/dump_table.txt"
echo "[hb-host] running host harness on $FIX3 ..."
if ! "$BIN" "$FIX3" 600 >"$DUMP3" 2>&1; then
    echo "[hb-host] FAIL: table harness exited non-zero"; cat "$DUMP3"; exit 1
fi
cat "$DUMP3"

assert_grep3() {
    local pat="$1" msg="$2"
    if grep -Eq -- "$pat" "$DUMP3"; then
        echo "[hb-host] PASS $msg"
    else
        echo "[hb-host] FAIL $msg (missing: $pat)"; fail=1
    fi
}

# Column x-positions are computed from the WIDEST cell per column:
#   col0 "Blueberry"(9) -> next col at 8+(9+2)*8 = 96
#   col1 "Colour"(6)    -> next col at 96+(6+2)*8 = 160
# Header + every body row must share these exact column x-positions.
assert_grep3 '^SEG 2 8 #101010 b1 .*Fruit\|'   "th 'Fruit' bold at col0 x=8"
assert_grep3 '^SEG 2 96 #101010 b1 .*Colour\|' "th 'Colour' bold at col1 x=96"
assert_grep3 '^SEG 2 160 #101010 b1 .*Qty\|'   "th 'Qty' bold at col2 x=160"
assert_grep3 '^SEG 3 8 #101010 b0 .*Apple\|'   "td 'Apple' plain at col0 x=8"
assert_grep3 '^SEG 3 96 #101010 b0 .*red\|'    "td 'red' at col1 x=96 (aligned to header)"
assert_grep3 '^SEG 3 160 #101010 b0 .*12\|'    "td '12' at col2 x=160 (aligned to header)"
assert_grep3 '^SEG 4 96 #101010 b0 .*blue\|'   "wide row 'Blueberry' keeps col1 at x=96"
# Per-cell colour + background survive the column placement.
assert_grep3 '^SEG 6 8 #101010 b0 u0 l-1 bg#c0c0c0 .*Lime\|' "td bgcolor=silver fills the cell (#c0c0c0)"
assert_grep3 '^SEG 6 96 #008000 .*green\|'                   "font color=green inside a cell -> #008000"
# The FLOW reconstruction shows the columns aligned as a grid.
assert_grep3 '^FLOW  Fruit      Colour  Qty$'  "FLOW renders the header row as aligned columns"
assert_grep3 '^FLOW  Blueberry  blue    340$'  "FLOW renders the wide row aligned to the same columns"

# ====================================================================
# LIST fixture — <ul>/<ol>/<li> markers, ordered numbering, <ol start=>,
# nesting, and hanging indent (marker in the gutter, item text + wrapped
# continuation lines aligned one level in).
#   level 1 text indent = CONTENT_X(8) + 1*LIST_STEP(32) = 40
#   level 2 text indent = 8 + 2*32                       = 72
# The marker hangs at (text_indent - LIST_STEP): level1 -> x=8, level2 -> x=40.
# ====================================================================
FIXL="tests/fixtures/hambrowse_lists.html"
DUMPL="$OUT/dump_lists.txt"
echo "[hb-host] running host harness on $FIXL ..."
if ! "$BIN" "$FIXL" 600 >"$DUMPL" 2>&1; then
    echo "[hb-host] FAIL: lists harness exited non-zero"; cat "$DUMPL"; exit 1
fi
cat "$DUMPL"

assert_grepL() {
    local pat="$1" msg="$2"
    if grep -Eq -- "$pat" "$DUMPL"; then
        echo "[hb-host] PASS $msg"
    else
        echo "[hb-host] FAIL $msg (missing: $pat)"; fail=1
    fi
}

# <ul> item: '-' bullet in the gutter at x=8, item text hanging at x=40.
assert_grepL '^SEG 2 8 #101010 b0 u0 l-1 bg- \|-\|$'      "ul bullet marker '-' hangs at x=8"
assert_grepL '^SEG 2 40 #101010 b0 u0 l-1 bg- \|Apples\|' "ul item text hangs at x=40 (one level in)"
# A long item wraps and the continuation line aligns under the TEXT (x=40),
# NOT back under the marker — this is the hanging indent.
assert_grepL '^SEG 3 40 .*certainly wrap across the\|$'    "long ul item wraps at the text column"
assert_grepL '^SEG 4 40 .*available line width so we can check hanging indentation\|' \
    "wrapped continuation line aligns at x=40 (hanging indent, not x=8)"
# <ol> items number 1./2./3. in the gutter, text hanging at x=40.
assert_grepL '^SEG 9 8 #101010 b0 u0 l-1 bg- \|1\.\|'   "ol first item numbered '1.' at x=8"
assert_grepL '^SEG 9 40 .*Preheat\|'                     "ol item text hangs at x=40"
assert_grepL '^SEG 10 8 .*\|2\.\|'                        "ol second item numbered '2.'"
assert_grepL '^SEG 11 8 .*\|3\.\|'                        "ol third item numbered '3.'"
# Nested <ol> inside a <ul> item: outer '-' at x=8, inner '1.'/'2.' one level
# deeper (marker at x=40, text at x=72), and the inner counter restarts at 1.
assert_grepL '^SEG 15 8 .*\|-\|'      "nested: outer ul bullet at x=8"
assert_grepL '^SEG 15 40 .*Fruit\|'   "nested: outer ul item text at x=40"
assert_grepL '^SEG 16 40 .*\|1\.\|'   "nested: inner ol marker '1.' hangs at x=40"
assert_grepL '^SEG 16 72 .*Apple\|'   "nested: inner ol item text hangs at x=72"
assert_grepL '^SEG 17 40 .*\|2\.\|'   "nested: inner ol counter continues to '2.'"
# <ol start="10"> seeds the counter: items number 10./11.
assert_grepL '^SEG [0-9]+ 8 .*\|10\.\|'  "ol start=10 -> first item numbered '10.'"
assert_grepL '^SEG [0-9]+ 8 .*\|11\.\|'  "ol start=10 -> second item numbered '11.'"
# FLOW reconstruction shows the marker + hanging text.
assert_grepL '^FLOW  -   Apples$'    "FLOW shows ul bullet + item"
assert_grepL '^FLOW  1\.  Preheat$'  "FLOW shows ol number + item"

# ====================================================================
# CSS-CASCADE fixture — <style> rules with element/.class/#id/descendant
# selectors + specificity, font-weight, text-align (baked into seg_x),
# display:none, rgb()/named colours, and inline style="" overriding the sheet.
# ====================================================================
FIX4="tests/fixtures/hambrowse_css.html"
DUMP4="$OUT/dump_css.txt"
echo "[hb-host] running host harness on $FIX4 ..."
if ! "$BIN" "$FIX4" 600 >"$DUMP4" 2>&1; then
    echo "[hb-host] FAIL: css harness exited non-zero"; cat "$DUMP4"; exit 1
fi
cat "$DUMP4"

assert_grep4() {
    local pat="$1" msg="$2"
    if grep -Eq -- "$pat" "$DUMP4"; then
        echo "[hb-host] PASS $msg"
    else
        echo "[hb-host] FAIL $msg (missing: $pat)"; fail=1
    fi
}

# element `h1 { color:navy; text-align:center }` — navy + bold heading whose
# row is shifted right of the x=8 margin by the centring post-pass.
assert_grep4 '^SEG 0 (1[0-9][0-9]|[2-9][0-9][0-9]) #000080 b1 .*Centered Title\|' \
    "h1 style rule -> navy bold, centred (seg_x shifted right of margin)"
# #id beats element: rgb(0,128,0) green wins over p{color:#333}.
assert_grep4 '^SEG [0-9]+ 8 #008000 .*Lead paragraph green' \
    "#lead id rule with rgb() -> green (#008000), beats p element rule"
# element rule p{color:#333}.
assert_grep4 '^SEG [0-9]+ 8 #333333 b0 .*Normal gray paragraph' \
    "p element rule -> gray (#333333)"
# .class beats element; font-weight:bold applies.
assert_grep4 '^SEG [0-9]+ 8 #ff0000 b1 .*Warning bold red' \
    ".warn class rule -> red + font-weight:bold (beats p element rule)"
# descendant `div p { background-color:yellow }` — bg fills, text stays p-gray.
assert_grep4 '^SEG [0-9]+ 8 #333333 b0 u0 l-1 bg#ffff00 .*Nested para on yellow' \
    "div p descendant rule -> yellow background, gray text"
# text-align:right baked into seg_x (line pushed to the right edge).
assert_grep4 '^SEG [0-9]+ ([4-9][0-9][0-9]) .*Right aligned line' \
    ".box text-align:right -> line shifted to the right edge"
# display:none — the hidden paragraph produces NO segment.
if grep -q 'should not see' "$DUMP4"; then
    echo "[hb-host] FAIL display:none did not skip the element"; fail=1
else
    echo "[hb-host] PASS display:none skips the element (no segment emitted)"
fi
# flow continues after a display:none element (skip terminated correctly).
assert_grep4 '^SEG [0-9]+ 8 #333333 .*Visible after hidden line' \
    "content after display:none still renders (skip name NUL-terminated)"
# inline style="" colour (rgb()) overrides the element sheet rule.
assert_grep4 '^SEG [0-9]+ 8 #0a14c8 .*Inline rgb override wins' \
    "inline style rgb(10,20,200) overrides p{color:#333}"
# inline style="text-align:center" also shifts seg_x.
assert_grep4 '^SEG [0-9]+ (1[0-9][0-9]|[2-9][0-9][0-9]) .*Inline centered paragraph' \
    "inline text-align:center -> centred line"

# ====================================================================
# JAVASCRIPT + minimal DOM fixture — <script> runs at load; console.log is
# captured; the DOM the script mutates (textContent, style.color,
# style.display) changes what renders; document.title is settable.
# ====================================================================
FIX5="tests/fixtures/hambrowse_js.html"
DUMP5="$OUT/dump_js.txt"
echo "[hb-host] running host harness on $FIX5 ..."
if ! "$BIN" "$FIX5" 600 >"$DUMP5" 2>&1; then
    echo "[hb-host] FAIL: js harness exited non-zero"; cat "$DUMP5"; exit 1
fi
cat "$DUMP5"

assert_grep5() {
    local pat="$1" msg="$2"
    if grep -Eq -- "$pat" "$DUMP5"; then
        echo "[hb-host] PASS $msg"
    else
        echo "[hb-host] FAIL $msg (missing: $pat)"; fail=1
    fi
}

# console.log output is captured and surfaced.
assert_grep5 '^JSLOG hello from js$'  "console.log string is captured"
assert_grep5 '^JSLOG 1\+1 = 2$'       "console.log evaluates + prints an expression (1+1=2)"
# getElementById(...).textContent = ... changes what renders.
assert_grep5 '\|JS set this heading\|' "textContent set on #head changes the heading text"
assert_grep5 '\|mutated by script\|'   "textContent set on #msg changes the paragraph text"
# The ORIGINAL placeholder text is gone (proves the mutation replaced it).
if grep -q 'Placeholder heading' "$DUMP5"; then
    echo "[hb-host] FAIL original #head text still rendered"; fail=1
else
    echo "[hb-host] PASS original #head placeholder text replaced by JS"
fi
# style.color set by JS -> the element renders in that colour.
assert_grep5 '^SEG [0-9]+ 8 #ff0000 .*\|tint me\|' "style.color='red' -> #ff0000 text"
# style.display='none' hides the element (no segment for its text).
if grep -q 'you should not see this hidden line' "$DUMP5"; then
    echo "[hb-host] FAIL style.display='none' element still rendered"; fail=1
else
    echo "[hb-host] PASS style.display='none' hides the element (no segment)"
fi
# The static (non-scripted) tail paragraph is untouched.
assert_grep5 '\|Static tail paragraph stays put.\|' "un-scripted content renders unchanged"
# document.title is settable from JS.
assert_grep5 '^TITLE Title From JS$' "document.title assignment reflected"

# ---- graceful JS error: a runtime error must not crash the render --------
cat > "$OUT/js_err.html" <<'HTML'
<html><body>
<p id="a">before</p>
<script>
  document.getElementById('a').textContent = 'set ok';
  bogusUndefinedRef.doStuff();
</script>
<p>after error</p>
</body></html>
HTML
DUMP6="$OUT/dump_js_err.txt"
if ! "$BIN" "$OUT/js_err.html" 600 >"$DUMP6" 2>&1; then
    echo "[hb-host] FAIL: js-error harness exited non-zero"; cat "$DUMP6"; exit 1
fi
cat "$DUMP6"
if grep -q 'JSERR 1' "$DUMP6"; then
    echo "[hb-host] PASS runtime JS error surfaced as JSERR"
else
    echo "[hb-host] FAIL runtime JS error not surfaced"; fail=1
fi
# the render survives the error: pre-error mutation applied + tail still renders.
if grep -q '|set ok|' "$DUMP6" && grep -q '|after error|' "$DUMP6"; then
    echo "[hb-host] PASS render survives a JS error (pre-error DOM change kept, page intact)"
else
    echo "[hb-host] FAIL render did not survive the JS error"; fail=1
fi

# ====================================================================
# EVENTS — a programmatic click (no pointer) fires a stored JS handler via
# js_call_fn in the persistent context, then re-lays-out. This is the
# acceptance path for interactivity.
# ====================================================================
FIXE="tests/fixtures/hambrowse_events.html"
# (a) el.onclick = fn  -> click #btn increments a counter the render reflects.
DUMPE="$OUT/dump_events_btn.txt"
echo "[hb-host] running host harness on $FIXE (click btn) ..."
if ! "$BIN" "$FIXE" 600 btn >"$DUMPE" 2>&1; then
    echo "[hb-host] FAIL: events harness exited non-zero"; cat "$DUMPE"; exit 1
fi
cat "$DUMPE"
assert_grepE() {
    local pat="$1" msg="$2"
    if grep -Eq -- "$pat" "$DUMPE"; then
        echo "[hb-host] PASS $msg"
    else
        echo "[hb-host] FAIL $msg (missing: $pat)"; fail=1
    fi
}
# Before the click the counter reads 0; the CLICK separator is emitted.
assert_grepE '^CLICK btn$' "programmatic click on #btn dispatched"
# After the click, the onclick handler ran: counter text updated + console.log.
assert_grepE '^JSLOG clicked, count=1$' "onclick handler ran (console.log after dispatch)"
# The post-click dump (after CLICK) shows the mutated counter text.
awk '/^CLICK btn$/{c=1} c' "$DUMPE" | grep -q '|count is 1|' && \
    echo "[hb-host] PASS el.onclick handler mutation rendered (count is 1)" || \
    { echo "[hb-host] FAIL onclick DOM mutation did not render"; fail=1; }
# The counter was 0 BEFORE the click (pre-click dump).
awk '/^CLICK btn$/{exit} {print}' "$DUMPE" | grep -q '|count is 0|' && \
    echo "[hb-host] PASS pre-click state was count is 0" || \
    { echo "[hb-host] FAIL pre-click state wrong"; fail=1; }

# (b) addEventListener('click', fn) -> click #msg mutates text + colour.
DUMPE2="$OUT/dump_events_msg.txt"
echo "[hb-host] running host harness on $FIXE (click msg) ..."
if ! "$BIN" "$FIXE" 600 msg >"$DUMPE2" 2>&1; then
    echo "[hb-host] FAIL: events harness (msg) exited non-zero"; cat "$DUMPE2"; exit 1
fi
cat "$DUMPE2"
if awk '/^CLICK msg$/{c=1} c' "$DUMPE2" | grep -Eq '#ff0000 .*\|msg was clicked\|'; then
    echo "[hb-host] PASS addEventListener('click') handler ran (text + red colour rendered)"
else
    echo "[hb-host] FAIL addEventListener click handler did not render"; fail=1
fi

# ====================================================================
# RICHER DOM — innerHTML, createElement+appendChild, className, querySelector,
# getAttribute/setAttribute, and background-color/font-weight/text-align.
# ====================================================================
FIXD="tests/fixtures/hambrowse_dom2.html"
DUMPD="$OUT/dump_dom2.txt"
echo "[hb-host] running host harness on $FIXD ..."
if ! "$BIN" "$FIXD" 600 >"$DUMPD" 2>&1; then
    echo "[hb-host] FAIL: dom2 harness exited non-zero"; cat "$DUMPD"; exit 1
fi
cat "$DUMPD"
assert_grepD() {
    local pat="$1" msg="$2"
    if grep -Eq -- "$pat" "$DUMPD"; then
        echo "[hb-host] PASS $msg"
    else
        echo "[hb-host] FAIL $msg (missing: $pat)"; fail=1
    fi
}
# innerHTML set to markup -> parsed + rendered (the <b> becomes bold).
assert_grepD '^SEG 0 8 #101010 b1 .*\|bold new\|' "innerHTML set -> <b> renders bold"
if grep -q 'old inner' "$DUMPD"; then
    echo "[hb-host] FAIL innerHTML did not replace original inner"; fail=1
else
    echo "[hb-host] PASS innerHTML replaced the original inner markup"
fi
# style.backgroundColor + fontWeight + textAlign together on #styled.
assert_grepD '^SEG [0-9]+ (1[0-9][0-9]|[2-9][0-9][0-9]) #101010 b1 .*bg#ffff00 \|style me\|' \
    "style.backgroundColor/fontWeight/textAlign -> yellow bg, bold, centred"
# className change -> the .warn CSS rule now applies (red + bold).
assert_grepD '^SEG [0-9]+ 8 #ff0000 b1 .*\|class target\|' \
    "element.className='warn' -> .warn CSS rule applies (red bold)"
# createElement + appendChild -> the new <li> renders, coloured green.
assert_grepD '#008000 .*\|appended item\|' "createElement+appendChild adds a green <li>"
# querySelector('.class') + getAttribute reflected via console.log.
assert_grepD '^JSLOG querySelector .warn text = warn para$' "querySelector('.warn') returns the element"
assert_grepD '^JSLOG getAttribute data-role = banner$'       "getAttribute reads a source attribute"
# setAttribute('class','warn') -> .warn rule applies to #attr.
assert_grepD '^SEG [0-9]+ 8 #ff0000 b1 .*\|attr target\|' \
    "setAttribute('class','warn') -> .warn CSS rule applies"

# ====================================================================
# FORMS — <input>/<textarea>/<button>/<select> rendering, the form DOM
# (value/checked/type/name, form.elements, document.forms), form events
# (oninput/onchange/onclick/onsubmit) fired via the pointer-free host hooks
# (he_dom_set_value / he_dom_set_checked / he_dom_submit), and GET-style
# serialization of a form that does NOT preventDefault.
# ====================================================================
FIXF="tests/fixtures/hambrowse_forms.html"

run_forms() {   # args passed straight to the harness after WIDTH
    "$BIN" "$FIXF" 600 "$@"
}

# ---- (0) initial render: every control draws a monospace box ------------
DUMPF="$OUT/dump_forms.txt"
echo "[hb-host] rendering $FIXF ..."
if ! run_forms >"$DUMPF" 2>&1; then
    echo "[hb-host] FAIL: forms harness exited non-zero"; cat "$DUMPF"; exit 1
fi
cat "$DUMPF"
assert_grepF() {
    local pat="$1" msg="$2" file="${3:-$DUMPF}"
    if grep -Eq -- "$pat" "$file"; then
        echo "[hb-host] PASS $msg"
    else
        echo "[hb-host] FAIL $msg (missing: $pat)"; fail=1
    fi
}
assert_grepF '^FLOW  Name field: \[hi______\]$' "text input renders [value] padded box"
assert_grepF '^FLOW  Subscribe: \[x\]$'         "checked checkbox renders [x]"
assert_grepF '^FLOW  Colour: \(\*\) red$'       "checked radio renders (*)"
assert_grepF '^FLOW  Notes: \[note text\]$'     "textarea renders its content in a box"
assert_grepF '^FLOW  Pick: \[ beta v\]$'        "select renders the selected option (beta)"
assert_grepF '^FLOW  \[ Save \]$'               "<button> renders a [ label ] box"
assert_grepF 'Search'                            "input type=submit renders a button"
# the hidden input renders nothing (no box) on the second form's line.
assert_grepF '^FLOW  \[dogs____\] \[ Go \]$'    "hidden input renders nothing (only visible fields box)"
# form DOM surface: input.type/name, select.value/selectedIndex, collections.
assert_grepF '^JSLOG name\.type=text$'  "input.type defaults to text"
assert_grepF '^JSLOG name\.name=who$'   "element.name reads the name attribute"
assert_grepF '^JSLOG pick\.value=beta$' "select.value returns the selected option text"
assert_grepF '^JSLOG pick\.idx=1$'      "select.selectedIndex returns the selected index"
assert_grepF '^JSLOG f1\.elements=3$'   "form.elements lists the form's controls"
assert_grepF '^JSLOG doc\.forms=2$'     "document.forms lists the page's forms"

# ---- (1) text input: he_dom_set_value fires oninput -> updates echo -----
DUMPF1="$OUT/dump_forms_setval.txt"
run_forms setval name Fluffy >"$DUMPF1" 2>&1
cat "$DUMPF1"
awk '/^SETVAL/{c=1} c' "$DUMPF1" > "$OUT/forms_after_setval.txt"
assert_grepF '^FLOW  Name field: \[Fluffy__\]$' \
    "he_dom_set_value updates the text input box" "$OUT/forms_after_setval.txt"
assert_grepF '^FLOW  echo: Fluffy$' \
    "oninput handler read input.value and updated another element" \
    "$OUT/forms_after_setval.txt"

# ---- (2) checkbox: he_dom_set_checked fires onchange --------------------
DUMPF2="$OUT/dump_forms_check.txt"
run_forms check sub 0 >"$DUMPF2" 2>&1
cat "$DUMPF2"
awk '/^CHECK/{c=1} c' "$DUMPF2" > "$OUT/forms_after_check.txt"
assert_grepF '^FLOW  Subscribe: \[ \]$' \
    "unchecking the checkbox re-renders [ ]" "$OUT/forms_after_check.txt"
assert_grepF '^FLOW  sub is off$' \
    "onchange handler read input.checked and updated the status line" \
    "$OUT/forms_after_check.txt"

# ---- (3) button onclick mutates the DOM --------------------------------
DUMPF3="$OUT/dump_forms_click.txt"
run_forms click go >"$DUMPF3" 2>&1
cat "$DUMPF3"
awk '/^CLICK/{c=1} c' "$DUMPF3" > "$OUT/forms_after_click.txt"
assert_grepF '^FLOW  saved!$' \
    "<button> onclick handler mutated the DOM" "$OUT/forms_after_click.txt"
# the pre-click state ('not saved') was present before the click.
awk '/^CLICK/{exit} {print}' "$DUMPF3" | grep -q 'not saved' && \
    echo "[hb-host] PASS pre-click button state was 'not saved'" || \
    { echo "[hb-host] FAIL pre-click button state wrong"; fail=1; }

# ---- (4) onsubmit reads values + preventDefault stops navigation -------
DUMPF4="$OUT/dump_forms_submit1.txt"
run_forms submit f1 >"$DUMPF4" 2>&1
cat "$DUMPF4"
awk '/^SUBMIT/{c=1} c' "$DUMPF4" > "$OUT/forms_after_submit1.txt"
assert_grepF '^FLOW  searched cats fancy=yes$' \
    "onsubmit read input.value + input.checked and updated the page" \
    "$OUT/forms_after_submit1.txt"
assert_grepF '^JSLOG submit q=cats$' \
    "onsubmit handler ran (console.log captured)" "$OUT/forms_after_submit1.txt"
# preventDefault() was honoured: NO navigation happened.
if grep -q '^NAV ' "$OUT/forms_after_submit1.txt"; then
    echo "[hb-host] FAIL preventDefault ignored (form navigated anyway)"; fail=1
else
    echo "[hb-host] PASS onsubmit preventDefault suppressed navigation (no NAV)"
fi

# ---- (5) a form WITHOUT preventDefault GET-serializes its fields --------
DUMPF5="$OUT/dump_forms_submit2.txt"
run_forms submit f2 >"$DUMPF5" 2>&1
cat "$DUMPF5"
awk '/^SUBMIT/{c=1} c' "$DUMPF5" > "$OUT/forms_after_submit2.txt"
assert_grepF '^NAV \?term=dogs&lang=en$' \
    "form without preventDefault serializes visible+hidden fields (submit button excluded)" \
    "$OUT/forms_after_submit2.txt"

if [ "$fail" -eq 0 ]; then
    echo "[hb-host] RESULT: PASS"
    exit 0
else
    echo "[hb-host] RESULT: FAIL"
    exit 1
fi
