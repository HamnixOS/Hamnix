# Real-use bug report — 2026-07-21 (USER, default -O0 installer image)

Found by actually using the booted desktop. Triaged by the orchestrator.
NOTE: image was default `-O0` (HAMNIX_KERNEL_OPT=0) — NOT the SSA/--opt path, so
these are pre-existing bugs, not opt-cutover regressions.

## Tier 1 — system stability (CRITICAL)
- [x] **#DF hang in `syscall_entry`** — FIXED (main, cli-before-user-RSP @ syscall_64.S; boot-verified)  
  <details>original:</details> — double-fault (vec=8), CPL0 on USER stack,
  rip=0xffffffff805f26f9 = `syscall_entry`+0xa9 (fn @ 0x805f2650). Kernel faults
  while still on the user rsp → syscall-entry stack-switch bug (per-CPU kstack /
  swapgs / %gs base). Trips under heavy syscall load ("while typing a lot"). = the hang.
  → AGENT (kernel).
- [x] **RAM only ever goes UP** (FIXED main: (B) reporting bug — meminfo now counts buddy free pool, not just order-0 list) — closing apps doesn't free memory (mem_gate log:
  free stuck at 1466512 before/after). Either a real kernel leak (task teardown
  not reclaiming pages) OR System Monitor reads wrong. Confirm which.

## Tier 2 — browser (directive: render like Chrome / run most websites)
- [x] **Google** (FIXED main: top-level `this`→global; JS iterator/Object gaps): main search page renders badly; searching → `JS: uncaught
  TypeError: ze is not a function`. JS-engine gap (minified Google JS).
- [x] **Google desktop full-site BLANK** (FIXED main 92db33ea): the whole rendered body was silently dropped. Root cause was NOT a DOM-wipe — desktop google ships ~1.1MB inline JS *before* `<body>`, and `_strip_comments` in `lib/web/dom/bindings.ad` capped source at 256KiB (`CS_CAP`/`RW_CAP`), truncating everything past byte 262144. Raised caps to 4MiB end-to-end (engine + hambrowse read paths) + >256KiB regression fixture. Live google now renders: color logo, app-grid, About/Store, search prompt, Upload/Tools/Create/Canvas/AI-Mode controls. RESIDUAL (open, real-pattern): (a) layout not centered like real google; (b) decimal numeric char-ref `&#127820;` (astral emoji 🎨) not decoded; (c) one image = broken-placeholder.
  - [x] **(a) centering FIXED main 702e3fe8**: real cause was `MAX_RULES=256` — google's `.LS8OJ{justify-items:center}` is rule #833 in a ~1200-rule sheet, silently dropped. Raised rule/selector/pool caps (256→2048 etc), added grid/flex-column `justify-items/align-items:center`→text-align-center mapping, stopped `max-width:100%` pinning intrinsic img width. Logo now centered ~x=510, searchbox centered. VERIFIED on the actual rendered PNG (not just synthetic gates — prior agent's synthetic-only pass was the trap).
  - [x] **(b) `&#127820;` in button labels FIXED main 702e3fe8**: the `<button>` label scan copied raw source bytes; now decodes numeric/named entities. (Decode already worked in the text-dump harness; the paint path needed it too.)
  - **(c) broken image = EXPECTED** (relative-URL logo the offline host render can't fetch; not a bug).
  - **Google fidelity — big buildout 2026-07-22 (main ffa378b6).** From blank → recognizable homepage: centered color logo + tagline, search input fills the bar w/ AI-Mode pill, google-styled submit buttons (centered labels), About/Store top-left w/ gap, app-grid top-right, footer Build-on-top + Advertising-left/Privacy-right. Landed: calc-height %, MAX_RULES 256→2048, bare-N%→auto, inline-SVG width-decline + unsized-viewBox 24px fallback, display:none depth-skip, chip margins, submit-button CSS, AI-Mode fill, button vcenter, flex `order`+wrap-relocate, flex-child hidden-descendant measurement skip, flex-item blockification, **runtime CSSOM insertRule/adoptedStyleSheets/dynamic-style→re-cascade**. OPEN: (a) Gmail/Images STILL hidden — CSSOM works but google's reveal JS throws **`maft is not a function`** (a minified-JS engine gap, NOT CSSOM) before it runs — next google lever is that JS gap; (b) search input paints as thin bar not full-height field (vertical paint); (c) footer Settings wraps (nested popup divs); (d) app-grid ~40px vertical offset (inline-SVG box height); (e) About/Store "o" sub-pixel baseline (font_ttf, not worth the risk). Further google-specific fidelity = chasing minified-JS errors (diminishing ROI).
  - **Multi-site buildout 2026-07-22 (main 6ef6df72):** google + Hacker News + Wikipedia + MDN + BBC + danluu-blog all render. Landed: explicit-table-width (HN `<center><table width=85%>`), landmark-float+dropdown-collapse (Wikipedia article un-buries; refined to `<aside>`-only so MDN/BBC top-`<nav>` bars don't overlap), broken-`<img>` percentage-decline (BBC 44×1184px→40×32 compact), JS `performance`+`document.fonts` (killed google `maft`), `XMLHttpRequest`, CSSOM insertRule/adoptedStyleSheets. **KEY FINDING: external `<link>` CSS is ALREADY fully implemented + working** (`he_css_scan_links`/`_collect_css` engine + `user/hambrowse.ad` http9 fetch + host sibling-`.css` resolve); the `extcss` gate was a STALE-assertion false-fail (x=158→8 + `s0` field), now PASS. So MDN/BBC host-render limits are just **remote-URL CSS not fetchable on the no-network host gfx path** — on-device hambrowse fetches them. Browser is in strong shape; remaining host-render gaps are network-bound (would render correctly on-device) or minor polish (reddit horiz-nav, BBC card-grid — both need the external CSS that works on-device).
  - **NEW residual (open)**: vertical fidelity — google's `calc(100%-560px)` hero heights push the logo/searchbox low + some button overlap bottom-right. Horizontal centering done; `calc()`-based block heights are the next browser gap.
  - **Google fidelity push 2026-07-22** (user driving real render iteration). FIXED: calc()-height % resolves against viewport-height not width (d5e497c); MAX_RULES 256→2048 dropped centering rule #833 (702e3fe8); bare `N%` height → auto not viewport (03b0cc20); inline-SVG `width:100%` resolved vs page not 24px parent → giant blob (aac6a65); display:none skip now depth-tracks nested divs (03b0cc20); top-nav inline-block chip margins threaded into pixel flow — "AboutStore" gap (4cc0176b); submit-button CSS (`#f8f9fa` pill, 8px radius, `#3c4043` label) via `is_btn` cascade-match (831ebc59). OPEN handoffs: (a) **FOOTER needs CSS `order` parsing** (NOT implemented in cascade.ad — google's `@media(max-width:1200px){.ssOUyb{order:0}}` reorders rows) + **flex-child natural-width measurement must include padding** (`_flex_measure_children` measures text only, ignores `.pHiOh{padding:15px}` → groups pack too tight, stack instead of `space-between` bar) + width:100%-wrap two-tier; (b) **nested-flex + flex-grow spacer + justify-content:flex-end** for top-right cluster (app-grid/Gmail/Images position); (c) **Gmail/Images need JS-injected-stylesheet exec** (google injects `.gb_R{display:block}` via CSSOM insertRule at runtime; static CSS only has display:none — proven via CDP); (d) logo perfect-centering (grid justify-items + symmetric padding subtract); (e) search-box internals (agent in flight).
- [x] **DuckDuckGo** (FIXED main: http9 now inflates Content-Encoding: gzip): fetch OK (HTTP 200, 41976 bytes) but renders BLANK white.
  Parse/layout drops the whole doc. HOST-reproducible (curl + hambrowse_gfx).
- [ ] **Networking flaky**: `fetch FAILED rc=-2` / `rc=-6` intermittent; YouTube
  lags then DNS/connect/TLS error. Some fetches succeed (200). DNS/TLS reliability.
  → AGENT (browser real-sites, HOST repro).

## Tier 3 — apps / UX
- [x] **Panel CPU applet = 0%** (FIXED main: shared lib/cpustat.ad reads /dev/stat) while System Monitor shows real CPU. Applet reads
  wrong source / not sampling.
- [x] **Software app** (FIXED main: strip hamnix- display + detect installed via /bin/<cmd>): apps show redundant `hamnix-` prefix; installed/available
  counts wrong (221 all / 23 installed / 198 available — not detecting installed).
- [x] **hamterm** (FIXED main: waitpid reap + Ctrl-D close): `exit` ends the shell prompt but does NOT close the window;
  Ctrl+D also doesn't. Window should close on shell exit ([hamterm] logs
  "shell exited; closing window" in one case but leaves it in the GUI case).
- [x] **Middle-mouse paste** (FIXED: paste hook was gated behind scrollback view): (X11 primary selection): mouse MIDDLE is seen
  (Input Event Inspector shows it) but paste doesn't happen. Ctrl+C/V works.
  → primary-selection buffer not wired to middle-click.
- [x] **Audio** (FIXED: file buffer 320KiB→4MiB; decoder was fine): `hamnix-music-demo.mp3` = "unreadable audio" but test.mp3 +
  test.wav work. Specific MP3 (bitrate/format variant) the decoder chokes on.
  HOST-checkable (run mp3decode on the file).
- [x] **No boot-up sound** (FIXED: jingle hook was in disabled legacy panel; now fires from live desktop) played.
- [x] **Snake (hamgame)**: after a few rounds slows way down AND leaves green
  cells behind the snake (trail not cleared) — perf degradation + stale-cell paint.

## Dispatch waves
- Wave 1 (now): kernel #DF; browser real-sites (Google/DDG/JS/net).
- Wave 2: apps cluster (panel CPU, software counts/prefix, hamterm close);
  audio (mp3 + boot sound); middle-paste; snake; RAM-leak-vs-sysmon.

## CI hygiene
- [x] Foundational `test_hambrowse_host.sh` 15 FAIL→0 (stale snapshot from landed proportional-column + border-model improvements; gate updated to match real Chrome-close output, no engine change).

## Chrome-parity roadmap (measured 2026-07-23, main 94c9c97f — SSIM/brmse vs chromium)
Ranked hambrowse-vs-Chrome gaps by cross-site impact (agent acdff02e):
1. **Text too wide → early wrap → ~2× inflated page height** (TOP impact; every text page; HN SSIM 0.402, titles wrap to 2 lines). Cause: hambrowse glyph-advance metrics (DejaVu Sans) wider than Chrome's default face. Fixing lifts every real-page score. ← NEXT.
2. flex-direction:column blockification — **FIXED 94c9c97f** (flexbox SSIM 0.663→0.729).
3. `font-family: serif`/`monospace` generic-family selection (serif pages render sans).
4. Header/nav table-cell sizing so single-line headers don't wrap (compounds #1).
5. Default vertical rhythm (line-height, heading/paragraph margins).
6. justify-content spacing nuances; flex/block background-bar FILL emission (dispflex/flexnav fails).
Tooling: `chromium` @ /usr/bin (Chrome ref); `framediff_gfx_*` SSIM harness; self-contained inline-CSS pages give clean comparisons.

## Chrome-parity progress (round 2, main 14b39ad7)
CLOSED so far: flex-column blockification (SSIM 0.663→0.729); #1 text-too-wide (DejaVu→Liberation condensed metric, HN 0.427→0.451); list `<li>` vertical margins (danluu blog 0.558→0.648, zero churn — gated on authored margin). Serif empirically ruled out as a big lever (+0.01). Re-ranked remaining gaps:
1. Header/nav `<table>`-cell sizing → single-line headers don't wrap (HN 0.563).
2. MDN-class two-column sidebar/main (0.709 — nav renders as narrow 284px col, main pushed below; grid/flex two-pane collapse).
3. Article-column max-width (Wikipedia hb content 995px vs Chrome 355px).
4. `font-family: serif`/`monospace` generic-family selection (low cross-site impact).

## Chrome-parity progress (round 3, 2026-07-23)
CLOSED: **nested `<table width="100%">` now STRETCHES to fill its parent cell** (the
Hacker News orange nav-bar pattern `<td bgcolor=#ff6600><table width=100%>…`). Before,
a nested width table shrank to its content and stranded the right-aligned `login`, so
`Hacker News new | past | … | submit` wrapped to a 2nd line; now the nav renders on ONE
line like Chrome. Fix: a nested table honours its width attribute, bounded to the parent
cell's right edge (`_compute_cols` stretch no longer gated to `cell_active==0`;
forms.ad `<table>` open reads the width attr for nested tables too). HN brmse 0.133→0.119
(the harness's PRIMARY structural distance improves); SSIM 0.563→0.562 (neutral — the raw
SSIM is confounded by HN's uncorrected vertical row-inflation, below). Non-table pages
(wiki/mdn/blog) byte-identical; wiki/mdn/google spot-checks unchanged. New host gate
`test_hambrowse_nesthdr_host.sh` (fixtures `hambrowse_nesthdr{,_auto}.html`): asserts the
nested width=100% right-cell reaches the viewport edge (632/640) vs an un-sized control
that stays content-width (188) — fails on base (188 both).

ATTEMPTED-BUT-DEFERRED this round (kept OUT to avoid a headline-metric regression):
**auto-column cap → container width** (so a long story title stays on one line instead
of wrapping at the fixed 480px per-column cap). Correct in isolation (clean full-width
table fixture brmse 0.227→0.184, titles single-line) BUT it interacts badly with HN's
`<center><table width=85%>`: the nested story table's now-uncapped natural width exceeds
the outer table's 85% target, so the OUTER table loses its explicit-width clamp and
overflows FULL-WIDTH (dropping the `<center>` gutter Chrome shows), spiking HN brmse
0.119→0.210. Prerequisite for that fix → **clamp an explicit-width table to its target
(wrap wide content at the target, don't let a wide descendant overflow it)**.

Re-ranked remaining gaps (round 4):
1. **HN vertical row-inflation** (NEW top lever; hb 1988px vs Chrome 1430px = 1.39×).
   Root-caused: table cells share the GLOBAL `cur_row`, so a block element inside one
   cell inflates the whole row — the empty `<div class="votearrow">` in HN's votelinks
   cell alone adds ~18px/story (isolated: story block 35px→53px with the div). Chrome
   gives an empty styleless block 0 height. This vertical mismatch dominates the raw
   SSIM (the metric's vertical-stretch normalization amplifies/inverts it), so it must
   land before horizontal table fixes can move SSIM. Fix = independent cell row-flow OR
   collapse empty in-cell blocks — a row-model change, sized as its own round.
2. Explicit-width table target CLAMP (prereq for the auto-column-cap title fix above).
3. MDN two-column sidebar/main (0.709).
4. Article-column max-width (Wikipedia).

## Chrome-parity round 4 (main after 0d9256a8)
CLOSED: HN vertical row-inflation — empty block (`div.votearrow height:10px`) in a `<td>` was adding 2 rows/story via shared `cur_row` (`g_cell_pending` skips the cell's leading soft-newline; empty sub-LINE_H block collapses to 0 rows; both gated to inside-cell so non-table flow byte-identical). **HN page height 2000→1696px (1.39×→1.18× vs Chrome ~1438px)**, isolated repro 233→119px. NOTE: full-frame SSIM harness reads vertical-fidelity gains as WORSE (resize misregistration) — use page-height + side-by-side, not raw resized SSIM, for vertical changes.
Round-5 lever: cell/row content-line height — a single-line cell occupies ~2 quantized LINE_H(16→18px) rows vs Chrome's ~1 text line (17px); investigate per-row leading/`_bump_row` pitch inside cells.
