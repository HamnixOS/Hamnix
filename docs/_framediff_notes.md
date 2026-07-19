## Committed sample montages

Two representative side-by-side montages are checked in as durable proof (the
per-run PNGs under `build/framediff/` are ephemeral):

- `tests/framediff/results/sample_grid_sxs_chromium.png` — CSS grid: tracks
  align, but hambrowse draws the `1px solid` card borders as ASCII `+--+ | |`.
- `tests/framediff/results/sample_form_sxs_chromium.png` — form controls: text
  inputs render as `[ke7oxh__]` (value text inline with the bracket "border"),
  reproducing the reported "text slightly outside the input box".

## Reading the score

- **Lower is closer.** The number is RMSE over the whole normalized content
  pane, so it moves when layout geometry, colour, or text placement drifts from
  the reference. Track it PER PAGE across engine commits — a drop means that
  page got closer to a real browser.
- There is a **non-zero floor** (~0.05–0.10 normalized on text-heavy pages) that
  no amount of engine work removes with this harness, because hambrowse paints
  glyphs on a fixed 8px cell / 16px line grid while chromium/firefox use
  proportional, sub-pixel-hinted fonts. `compare` is run with `-fuzz 8%` on the
  AE metric to discount pure antialiasing noise, but the grid-vs-proportional
  text difference is structural, not noise.
- Use the **side-by-side montage** (`sxs_<engine>.png`: hambrowse | reference |
  heatmap), not the scalar alone, to decide whether a regression is real. The
  heatmap's red mass localises the disagreement.

## Harness artifacts vs real fidelity gaps

These are HARNESS artifacts — do not "fix" the engine for them:

- **Vertical resize.** The reference is resized to the hambrowse content height,
  so a page where hambrowse packs content shorter than the browser gets a small
  uniform vertical stretch. Headings still roughly correspond; fine detail rows
  may smear in the heatmap.
- **Monospace corpus font.** The corpus pages set `font-family: "DejaVu Sans
  Mono", monospace` on purpose, so the reference browser uses the SAME face
  hambrowse renders — this makes advance widths comparable and keeps the score
  about LAYOUT, not font substitution. On real-world pages (proportional fonts)
  expect a much larger, font-dominated delta.
- **Chrome strip.** hambrowse's PNG includes window chrome (title/address/status
  bars); the harness crops it (top 38px, bottom 16px) before diffing. If the
  engine's chrome geometry changes, update `CHROME_TOP/CHROME_BOT` in
  `scripts/framediff_prep.py`.

These are REAL fidelity gaps the score is legitimately catching (see the
per-page montages):

- **Box borders drawn as ASCII art.** `border:1px solid` on grid cards / table
  cells / inputs renders in hambrowse as `+---+ | |` box-drawing text instead of
  thin CSS rules, so bordered boxes read very differently from the reference.
  This is the single largest structural contributor on the grid/table/form
  pages.
- **Form controls.** Text inputs, checkbox/radio, select and button chrome are
  approximated; watch the form page's heatmap for text drawn at/over the input
  box edge (the reported "text slightly outside the input box" symptom).
- **Line-box height.** hambrowse's fixed 16px line height vs the browser's
  font-metric line boxes shifts baselines progressively down a long page.

## Pitfalls handled

- **Viewport / DPR.** chromium runs with `--force-device-scale-factor=1` and a
  matched `--window-size=<width>,…`; firefox with a matched `--window-size`. No
  HiDPI doubling.
- **Scrollbars.** chromium `--hide-scrollbars`; the reference is trimmed to its
  content bbox so a scrollbar gutter can't skew width.
- **Background / alpha.** chromium `--default-background-color=FFFFFFFF` and an
  opaque white page background in every corpus page, matching hambrowse's white
  page, so transparent regions don't diff as black.
- **Antialiasing noise.** `-fuzz 8%` on the AE metric.

## Adding a page

Drop a self-contained, deterministic (no network) `.html` under
`tests/framediff/pages/` and re-run `scripts/framediff_all.sh`. Keep it
offline and fixed so the score is reproducible.
