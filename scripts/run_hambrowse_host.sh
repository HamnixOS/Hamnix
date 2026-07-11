#!/usr/bin/env bash
# scripts/run_hambrowse_host.sh — render an HTML page with the NATIVE browser
# engine (lib/htmlengine.ad + lib/jsengine.ad) on THIS Linux host and OPEN it as
# an image. No QEMU, milliseconds. This is the "see what hambrowse renders" GUI.
#
#   bash scripts/run_hambrowse_host.sh                 # built-in demo page
#   bash scripts/run_hambrowse_host.sh page.html       # your own page
#   bash scripts/run_hambrowse_host.sh page.html 900   # + render width
#   OUT=/tmp/x.png bash scripts/run_hambrowse_host.sh page.html   # choose output
#
# It runs build/host/hambrowse_host (the real engine compiled for x86_64-linux)
# and rasterizes the layout to a PNG via scripts/render_hambrowse_png.py.
set -uo pipefail
cd "$(dirname "$0")/.."

PAGE="${1:-}"
WIDTH="${2:-880}"
OUT="${OUT:-/tmp/hambrowse.png}"

# Build the host browser if it isn't there. (The gate builds it; assertion
# failures don't matter here — we only need the binary.)
if [ ! -x build/host/hambrowse_host ]; then
    echo "[run] building build/host/hambrowse_host ..." >&2
    bash scripts/test_hambrowse_host.sh >/dev/null 2>&1 || true
fi
[ -x build/host/hambrowse_host ] || { echo "[run] ERROR: could not build build/host/hambrowse_host" >&2; exit 1; }

# Default demo page (exercises CSS classes, headings, list, table, JS DOM).
CLEAN_PAGE=0
if [ -z "$PAGE" ]; then
    PAGE="$(mktemp --suffix=.html)"; CLEAN_PAGE=1
    cat > "$PAGE" <<'HTML'
<html><head><title>Hamnix Native Browser</title><style>
  h1 { color: navy; text-align: center; }
  .card { border: 1px solid black; margin-left: 16px; }
  .warn { color: red; font-weight: bold; }
  #total { color: green; }
  a { color: #1a5fb4; }
</style></head><body>
<h1>Hamnix Native Browser</h1>
<div class="card">
  <p>This page is rendered by <b>lib/htmlengine.ad</b> on the Linux host — no QEMU.</p>
  <p class="warn">CSS cascade, ES6+regex JavaScript, DOM, events, forms, lists and tables — all native.</p>
</div>
<h2>What works</h2>
<ul><li>ES6 + regex JavaScript engine</li><li>DOM + events + forms</li><li>Lists, tables, box model</li></ul>
<table><tr><th>Feature</th><th>Status</th></tr><tr><td colspan="2">shipping</td></tr></table>
<p>Computed by JavaScript: <span id="total">?</span> &mdash; see <a href="#">the source</a>.</p>
<script>
  var xs = [1,2,3,4,5];
  document.getElementById('total').textContent = 'sum = ' + xs.reduce((a,b)=>a+b, 0);
  console.log('regex /ham(nix)?/ on "hamnix": ' + /ham(nix)?/.test('hamnix'));
  console.log(`template literal: ${xs.length} items`);
</script>
</body></html>
HTML
fi

TITLE="$(basename "$PAGE")"
build/host/hambrowse_host "$PAGE" "$WIDTH" \
  | python3 scripts/render_hambrowse_png.py "$OUT" --url "file://$PAGE" --title "$TITLE"

[ "$CLEAN_PAGE" = 1 ] && rm -f "$PAGE"

echo "[run] rendered -> $OUT"
if command -v xdg-open >/dev/null 2>&1; then
    xdg-open "$OUT" >/dev/null 2>&1 &
else
    echo "[run] open $OUT to view (no xdg-open found)"
fi
