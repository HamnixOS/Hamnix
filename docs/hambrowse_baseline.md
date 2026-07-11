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
- Block: `h1 h2 h3`, `p`, `div`, `br`.
- Inline: `b`/`strong` (bold, nested-depth counted), `i`/`em`
  (parsed, rendered plain — no italic glyph set), `a href` (links).
- Lists: `ul`/`ol`/`li` (indented, `*` bullet).
- `pre`/`code` (whitespace preserved in `pre`).
- Dropped wholesale: `script style head title`.
- Entities: named `&amp; &lt; &gt; &quot; &apos; &nbsp;` + numeric
  `&#NN;`/`&#xHH;` (ASCII only; non-ASCII collapses to `?`).

**Layout**
- Single-pass block + inline flow, word-wrapped to the window width.
- Fixed monospace metrics: `CELL_W=8`, `LINE_H=16`. No variable font
  sizes — headings are only **bolded**, same glyph box as body.
- Output model: a flat list of styled **segments** (a run of same-styled
  text on one row at a pixel X), plus per-row "heading rule" flags.
- Heading underline rules for `h1`/`h2`; list indent; `pre` verbatim.
- NO real box model: no per-element margin/padding/width (only list
  indent), no floats, no tables, no images.

**Style / colour**
- A fixed **4-entry palette by role**: body `#101010`, link `#1a4fd0`,
  heading `#14306e`, pre/code `#0a6b5a`. `seg_color` is a palette index.
- **No CSS at all**: `<style>` is dropped, `style="…"` attributes are
  ignored, and there is no `color=`/`<font>` support. Colour is a pure
  function of element role.

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

## Honest gap list (highest-value first)

1. **CSS colour** — `style="color:…"`, `<font color>`, named + hex.
   (Chosen as the first rung in this branch.)
2. **Tables** — `table/tr/td` with a two-pass column layout.
3. **Box model** — element margins/padding, `hr`, `blockquote`, `h4`–`h6`.
4. **Background colour** — `bgcolor` / `background-color`.
5. **Images** — at least `alt` text; later real decode.
6. **Redirects + content-type** in the fetch path.
7. **Variable font sizes** for headings (needs a hamUI font change).

## Where iteration was slow

The only way to see a render was a full installer-image QEMU boot
(`scripts/test_de_browser.sh`, ~6 min build + boot). This branch factors
the parse+layout+colour engine into `lib/htmlengine.ad` (pure, no hamUI /
no http9) and adds a **host** front-end `user/hambrowse_host.ad` built for
the `x86_64-linux` Adder target, so the engine can be exercised against a
local HTML fixture on the dev host in milliseconds — no QEMU. The native
`user/hambrowse.ad` keeps the Plan 9-shape fetch + hamUI render path
unchanged and shares the same engine.
