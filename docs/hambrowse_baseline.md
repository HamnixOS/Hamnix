# hambrowse capability baseline (2026-07)

An honest snapshot of what the native web browser `user/hambrowse.ad` can
actually do today, written before the dual-target + rendering-rung work in
this branch. Kept short and truthful so the next rung is chosen against
reality, not the header comment's aspirations.

## What it does today

**Fetch**
- HTTP/1.0 `GET` over the Plan 9 `/net` file tree via `user/http9.ad`
  (the same client `wget`/`curl` use). DNS through the in-kernel resolver;
  TLS via `net9.net_dial_tls`. This is Plan 9-shape — there is **no**
  BSD `socket()` anywhere in the path.
- Local files via `sys_open`/`sys_read` (and a `file://` prefix strip).
- The built-in `--demo` page (no network), used by the render gate.
- NOT: HTTP redirects, POST/forms, cookies, chunked transfer,
  content-type sniffing, caching.

**Parse** (tolerant, hand-rolled; unknown tags dropped, text kept)
- Block: `h1`–`h6`, `p`, `div`, `br`, `hr`, `blockquote`.
- Inline: `b`/`strong` (bold, nested-depth counted), `i`/`em`
  (parsed, rendered plain — no italic glyph set), `a href` (links),
  `span`/`font` (colour-bearing), `img` (alt-text placeholder).
- Lists: `ul`/`ol`/`li` (indented, `*` bullet).
- Tables: `table`/`tr`/`td`/`th` (two-pass column layout; `th` bold).
- `pre`/`code` (whitespace preserved in `pre`).
- Dropped wholesale: `script style head title`.
- Entities: named `&amp; &lt; &gt; &quot; &apos; &nbsp;` + numeric
  `&#NN;`/`&#xHH;` (ASCII only; non-ASCII collapses to `?`).

**Layout**
- Block + inline flow, word-wrapped to the window width. Tables get a
  **two-pass** column layout: pass 1 measures the widest cell (in chars)
  per column, pass 2 fixes pixel column x-positions; each `<tr>` is one
  visual row and cells place at their column x, clamped to the column's
  right edge (`_flow_right`).
- Fixed monospace metrics: `CELL_W=8`, `LINE_H=16`. No variable font
  sizes — headings are only **bolded**, same glyph box as body.
- Output model: a flat list of styled **segments** (a run of same-styled
  text on one row at a pixel X, carrying colour + background), plus
  per-row rule flags (`1` = heading underline, `2` = `<hr>`).
- Box-model basics: `h1`/`h2` underline rules, `<hr>` full-width rule,
  list + `blockquote` left indent, per-block blank-line vertical margin.
- **CSS box model on `<p>`/`<div>`**, routed through the FULL cascade so it
  works from `<style>` rules / `.class` / `#id` selectors AND inline
  `style=""` (inline wins per axis):
  - `margin`/`padding` (`-left`/`-right`/`-top`/`-bottom` + the 1–4 value
    TRBL shorthand). Left/right shift the content column and shrink the
    wrap width; top/bottom insert blank lines (px quantised at `LINE_H`).
  - `width` (px / em / %) pins the wrap column to `indent_x + width`.
  - `border` / `border-style` draws a char-grid box (`+---+` top+bottom
    rules, `|` side bars) and insets the content one cell each side.
  - **Unit map (char grid)**: `1em == 16px == 2 cells` wide / one line tall
    (`EM_PX`); `%` is of the body content width (`bw − 2·CONTENT_X`); `px`
    and unitless map straight to pixels.
- Still NO: floats, negative margins, real image decode (`alt` only).

**Style / colour**
- A fixed **4-entry palette by role**: body `#101010`, link `#1a4fd0`,
  heading `#14306e`, pre/code `#0a6b5a`. `seg_color` is a palette index.
- **CSS colour**: `style="color:…"` and `<font color>` / `color=`, named
  colours + `#rgb`/`#rrggbb`, resolved through a colour stack (links keep
  their blue role colour). `<style>` blocks are still dropped.
- **Background colour**: `bgcolor` attribute + `style="background-color:"`
  fill the box behind a segment's text (per-segment `seg_bg`), including
  table cells. Word-boundary parsing keeps `background-color` from being
  mistaken for the text `color`.

**Render**
- Draws a **hamUI scene display list** (`hamscene_glyphs/rect/fill/line`)
  to `/dev/wsys/<wid>/scene`; the kernel scene compositor rasterizes and
  z-blits it. Not a raw framebuffer. Bold via `hamscene_glyphs_bold`,
  link underlines, a scrollbar thumb, an editable address bar, a status
  bar.

**Interaction**
- Scroll (arrows/`j`/`k`/space/`b`/`g`/`G`/wheel), click-to-navigate
  links (relative / root-relative / absolute resolved; in-page `#anchors`
  ignored), an editable address bar (focus, type, Backspace/ESC,
  Enter/"Go"), and window-resize re-layout.

## Rungs landed in this branch

1. **CSS colour** — `style="color:…"`, `<font color>`, named + hex. ✅
2. **Tables** — `table/tr/td/th`, two-pass column layout, `th` bold. ✅
3. **Box model** — `hr`, `blockquote` indent, `h4`–`h6`, block margins,
   plus cascaded `margin`/`padding`/`width`/`border` on `<p>`/`<div>` from
   `<style>` classes/ids (not just inline). ✅
4. **Background colour** — `bgcolor` / `background-color`. ✅
5. **Images** — inline `alt`-text placeholder (`[alt]` / `[img]`). ✅

## Honest gap list (highest-value next)

1. **Real image decode** — `<img>` currently shows only `alt` text; needs
   a decoder (PNG/JPEG) + a hamUI image blit primitive.
2. **Table borders/grid + `colspan`/`rowspan`** — cells align but there
   are no drawn borders and no cell spanning; a cell wider than its
   column wraps within it but multi-row cells are not tracked.
3. **`<body>`/full-page background** — `bgcolor` fills only behind text,
   not the whole element box or the page.
4. **JavaScript** — entirely out of scope. A future JS engine would sit
   *between* parse and layout: build a mutable DOM from the parser, run
   script against it, then feed the resolved tree to the layout pass.
   Nothing here assumes a static token stream that would preclude it.
5. **Redirects + content-type** in the fetch path.
6. **Variable font sizes** for headings (needs a hamUI font change; noted
   — this branch does not touch `lib/hamui.ad`).

## Where iteration was slow

The only way to see a render was a full installer-image QEMU boot
(`scripts/test_de_browser.sh`, ~6 min build + boot). This branch factors
the parse+layout+colour engine into `lib/htmlengine.ad` (pure, no hamUI /
no http9) and adds a **host** front-end `user/hambrowse_host.ad` built for
the `x86_64-linux` Adder target, so the engine can be exercised against a
local HTML fixture on the dev host in milliseconds — no QEMU. The native
`user/hambrowse.ad` keeps the Plan 9-shape fetch + hamUI render path
unchanged and shares the same engine.
