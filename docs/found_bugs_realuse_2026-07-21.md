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

## Chrome-parity round 5 (main after ad8fb29b)
CLOSED (partial — the safe half): the "~2 rows per single-line cell" was NOT per-row pitch — measured a single-line cell is ONE 19px content row (Chrome ~17–22px), tighter than Chrome. The excess was a spurious TRAILING blank paragraph-gap row the `</table>` handler stranded via `_para_break()` after every top-level in-flow table (a `<table>` is a margin-0 block box → no gap). Replaced with `_soft_newline()` (scoped to the table-close path; non-table flow byte-identical). **Isolated single-line-cell table 119→100px; a single-row single-cell table now == a bare `<div>` (62px==62px). HN 1696→1677px.** New host gate `test_hambrowse_cellrowh_host.sh` (single-line cell == bare block height). No-regression: host/realsite/realarticle/tblwidth/nesttable/cellflow/nesthdr/cellempty/lineheight/valign/google all PASS.
Round-6 lever (GLOBAL — deferred per scope discipline, needs sign-off): the DOMINANT residual HN gap (~239px over Chrome's 1438) is **small-font line-height quantisation** — an 8pt subtext line (HN `.subtext`/`.subline`) renders at a full 19px LINE_H row where Chrome uses ~13px. Measured: 5×8pt lines span ~115px in hb vs ~65px in Chrome. This is a row-height-by-font-size change to the LINE_H grid (variable per-row height driven by the row's max font metric), affecting ALL small-font text (table AND prose), so it churns dozens of pixel gates — do NOT blanket-change global LINE_H. Plan: thread the row's max font-px into the htmlpage row-height pass (forms.ad `row_padt`/`row_padb` already carry per-row px), so a row whose content is entirely < base font gets a proportionally shorter height; gate on a small-font fixture + re-baseline shifted gates as Chrome-correct. Secondary: hb IGNORES `<tr height:5px>` spacer rows entirely (under-counts 5px/story) — a minor opposing error to fold in at the same time.

## Chrome-parity round 6 (worktree — LANDED the primary lever)
CLOSED: the small-font line-height quantisation. Root cause was NOT the LINE_H grid but `lib/htmlpage.ad` seeding **every** text row at a fixed `BODY_H=19` floor (`row_h[r]=BODY_H`), so any row whose glyph box is < 19px (all sub-16px text) stayed at 19 while large fonts already exceeded it (h1=38, 22px=25). Fix (`htmlpage_render` pass 1a, guarded): a row whose LARGEST font is < 16px, carries no explicit CSS line-height, and whose true glyph height (new `row_gh`/`row_ga` trackers) is below the body floor takes that glyph height instead. Rows at/above the 16px base, image rows, margin-gap rows and line-height'd rows are byte-identical.
**Measured vs `/usr/bin/chromium` (self-measuring getBoundingClientRect page):**
| font | Chrome | hb BASE | hb FIX |
|------|--------|---------|--------|
| 8pt  | 12 | 19 (+7) | 11 (−1) |
| 10px | 11 | 19 (+8) | 11 (exact) |
| 13px | 15 | 19 (+4) | 15 (exact) |
| 16px | 18 | 19 (+1) | 19 (unchanged) |

Synthetic HN-subtext page: 5×8pt subtext block **95→55px**; 4-line 8pt/10px/13px/16px page **body 76→56px == Chrome's exact 56**. Real fixtures shrank toward Chrome: website 1068→1033, signup 624→609, filter 727→700, filterlist 423→408, boxmodel 603→598, realarticle 1446→1442, uaelems 705→700.
**Blast radius (measured, all fixtures diffed base-vs-fix):** 27 fixtures shift pixel output (only pages with sub-16px text — `<small>`, UA h5/h6, 8-13px CSS). **Gate churn = 0 newly-failing gates:** every geometry gate over a shifted fixture still PASSES (they assert relational/specific-pixel invariants that survive the height change, not absolute page height) — bordercolor, borderside, button, fieldset, flexrowgap, flexwrap, grid, gridspan, iconbtn, pseudocss, wordwrap, filter, filterlist, gfx, host, realarticle, realsite, cellflow, cellrowh, nesttable, valign, lineheight all green. All RED gates (borderradius, border, boxsizing, fidelity, uaelems, website, accentind, boxshadow, abswidth, flexwrap_qa) were proven RED on base too (byte-identical PPM for no-small-font pages; base-swap reproduced the same failure) — pre-existing, not caused here. New gate `test_hambrowse_smallrowh_host.sh` (small-font row strictly shorter than the 16px base; native hambrowse compiles). Fixture `tests/fixtures/hambrowse_smallfont.html`.
**DEFERRED (scoped follow-up):** the secondary opposing error — hb ignores `<tr height:5px>` spacer rows. This is a distinct **engine table-layout** change (not the htmlpage row-height pass), lower value (5px/story) and higher risk (touches table gates), so it was kept OUT of the clean primary landing. Plan: mirror the existing `row_mgap` sub-row-px mechanism (forms.ad ~L2064) — on an empty `<tr>`/cell carrying an explicit `height` < LINE_H, emit ONE spacer row tagged `row_mgap = height px` so the pixel pass draws it at its true small height instead of dropping it.

## Chrome-parity round 7 (worktree — LANDED the primary lever)
Re-measured 2026-07-23 vs `/usr/bin/chromium` at width 1000 (hb canvas caps at 1000×2000). Ranked gaps: **1. Hacker News story titles WRAP to a 2nd line** (top lever — every story doubled in height; hb page 1658px vs Chrome 1438px = 1.15×, SSIM 0.537). 2. Blog/prose list-row vertical rhythm (danluu `<li>` pitch hb ~38px vs Chrome ~32px — flex-`<li>` margin path, SSIM 0.709). 3. MDN responsive mega-menu (hb renders the whole collapsed nav expanded, pushing the article down — a `display`/media-query/CSSOM concern, SSIM 0.720). 4. Wikipedia article-column max-width (SSIM 0.826, already closest). 5. `<tr height:5px>` spacer honoring (deferred r6, minor & OPPOSING — would make HN *taller*).

CLOSED: **#1 — the story-title wrap.** Root cause was NOT the font metric or the explicit-width stretch; the real HN story list is an **auto-width `<table>` (no width attr)**, and `_compute_cols` clamped every column at a fixed **60-char (480px) cap** ("stop a runaway column"). A ~90-char headline therefore wrapped even though its container was ~850px wide. Chrome sizes an auto column to its content bounded only by the container. Fix (`lib/web/layout/tables.ad` `_compute_cols`): replace the hard `60` cap with `colcap = avail / CELL_W` **floored at the old 60**, so a column NEVER shrinks below its previous width and only a >60-char column in a >480px container grows; the existing `bounded` rule still clamps the grid to the container right edge (no overflow — the round-3 regression prerequisite). The proportional free-space rule already pours most surplus into the now-wider text column, so a separate "flex-only distribution" experiment proved **redundant** and was dropped (byte-identical result, smaller diff).
**Measured (page height vs Chrome 1438):** HN **1658 → 1335px** (1.15× → 0.93×), every title on ONE line, story rows now align ~row-for-row with Chrome (see side-by-side). Synthetic HN fixture (long title in a wide table): page **138 → 119px** (2 rows → 1). Full-frame SSIM reads 0.537 → 0.493 — the **documented vertical-misregistration confound** (a shorter, more-correct page mis-registers against Chrome's taller frame); page-height + side-by-side are the honest signal for this vertical change, per the round-4 note.
**Blast radius (measured, ALL 221 fixtures diffed base-vs-fix at the 640px gate width):** **0 existing fixtures change** — the fix only engages for a table column > 60 chars in a container > 480px, which no committed fixture at 640px hits. **Gate churn = 0.** All required gates PASS: tblcolcap(new), tblwidth, nesthdr, nesttable, cellflow, cellrowh, smallrowh, host, google, realsite, realarticle. Pre-existing RED gates (infobox, website) proven **byte-identical base-vs-fix** (PPM `cmp`) — untouched. New gate `test_hambrowse_tblcolcap_host.sh` (fixture `hambrowse_tblcolcap.html`): a long title fits ONE line in a wide table (page 62px) yet still wraps in a narrow one (480px → 81px, proving the cap tracks the container); native hambrowse compiles.

Re-ranked remaining gaps (round 8):
1. **Blog/prose list-row vertical rhythm** — danluu `<li>{display:flex;margin:0 0 .9em}` pitch hb ~38px vs Chrome ~32px (~6px/row over ~200 rows). Flex-`<li>` content-row + margin path; general prose lever.
2. **HN residual** — narrow rank/vote columns still a touch wider than Chrome (title starts ~150 vs ~100px); and the inline sitebit `(domain)` sits with extra whitespace before it rather than tight after the title.
3. **MDN responsive mega-menu collapse** — the desktop nav is a click-dropdown Chrome hides; hb renders it fully expanded (needs media-query `display:none` / CSSOM). Big MDN-class lever but complex.
4. Wikipedia article-column max-width (SSIM 0.826).
5. `<tr height:5px>` spacer honoring (still deferred; opposing sign to any height fix).

## Chrome-parity round 8 (worktree — LANDED the primary lever)
Re-measured 2026-07-23 vs `/usr/bin/chromium` at width 1000. Ranked gaps confirmed:
**1. Blog/prose list-row vertical rhythm** (top general lever; danluu index, SSIM
0.709, hb item pitch **38px vs Chrome 32px**). 2. HN residual (page confounded by the
round-7 vertical shortening; SSIM 0.493). 3. MDN mega-menu (0.720). 4. Wikipedia
max-width (0.826).

CLOSED: **#1 — list-item sub-row margin PIXEL height.** Root cause was NOT flexbox:
a block `<li>` and a `display:flex` `<li>` measured **identically** (both 38px). The
gap is entirely the **authored bottom margin**. `li{margin:0 0 .9em}` = 14.4px
quantises to exactly ONE blank grid row, and hambrowse drew that lone gap row at the
full `BODY_H` (~19px) body line pitch — so every item ran 19(content)+19(gap)=38px
instead of Chrome's 19+14≈32. The `<li>` inter-item-margin path (`lib/web/dom/forms.ad`)
emitted the gap via `_emit_vgap` but never tagged its px. Fix: tag the lone emitted gap
row with its REAL px via `row_mgap` — the *identical* mechanism the heading
margin-bottom already uses (the `lib/htmlpage.ad` per-row pass then draws `mg` px when
`mg < BODY_H` instead of a full body row). Guarded to fire only when the emit ran with
the previous item's row still dirty (the common single-line item) and the gap rounds to
one row.
**Measured:** danluu index item pitch **38 → 33px** (Chrome 32 — within 3%, was 19%
over); synthetic 6-item `li{margin:.9em}` list pitch 38 → 33. Full-frame blog SSIM reads
0.709 → 0.699 — the **documented vertical-misregistration confound** (a denser, more
Chrome-correct page mis-registers against Chrome's frame); item pitch + side-by-side are
the honest signal, per the round-4 note.
**Blast radius (all 222 fixtures diffed base-vs-fix at the 640px gate width):** **0
fixtures change** — the path fires only for a sub-`BODY_H` `li` margin that rounds to one
row, which no committed 640px fixture hits. **Gate churn = 0.** HN / MDN / Wikipedia real
pages **byte-identical** (HN's story list is a `<table>`, not an `li` list; the others
carry no sub-row li margin). All required gates PASS: host, google, realsite,
realarticle, tblwidth, tblcolcap, nesttable, nesthdr, cellflow, cellrowh, smallrowh,
limargin, navgap. New gate `test_hambrowse_limarginpx_host.sh` (fixture
`hambrowse_limargin_px.html`): the 4 inter-item gap rows of a 5-item `li{margin:.9em}`
list are drawn at 14px while a `margin:0` control adds no short row (base: all 12 rows a
flat 19px → FAIL). Native hambrowse compiles.

Re-ranked remaining gaps (round 9):
1. **HN residual** — narrow rank/vote columns still a touch wider than Chrome (title
   starts ~150 vs ~100px); inline sitebit `(domain)` carries extra leading whitespace
   rather than sitting tight after the title.
2. **MDN responsive mega-menu collapse** — desktop nav is a click-dropdown Chrome hides;
   hb renders it fully expanded (needs media-query `display:none` / CSSOM). Big MDN-class
   lever but complex.
3. Wikipedia article-column max-width (SSIM 0.826, closest).
4. Prose paragraph rhythm / heading margins on long-form articles (next general lever
   after list rhythm).
5. `<tr height:5px>` spacer honoring (still deferred; opposing sign to any height fix).

## Chrome-parity progress (rounds 9–11 + heading colour, main 8cf14fd7)
CLOSED, each measured vs `/usr/bin/chromium`, orchestrator-verified 0-newly-failing:
- **Round 9 (77374a7c): prose paragraph rhythm** — `<p>`/`<figure>` inter-paragraph gap
  was drawn at the full ~19px BODY_H row; now tagged at the real UA 16px via `row_mgap`
  (`g_para_mgap`). p→p gap 19→**16px (exact Chrome)**; paragraph pitch 38→35 (Chrome 34).
  Margin collapse preserved (a `</p><h2>` boundary keeps the taller heading margin).
- **Round 10 (33d54238): grid/flex inter-row gap over-height** — a `display:grid;gap:16px`
  of padded/bordered cards stranded a phantom LINE_H row between grid rows (`_flex_item_close`
  measured the row bottom from `cur_row`, overshooting the item border-box). Now measured
  from the item's own outer box. Inter-card-row gap 37→**18px** (Chrome 16); SSIM 0.745→0.814.
  ALSO: **disproved the ranked-#1 Wikipedia article-max-width lever** — the saved fixture's
  container max-width lives in external CSS the offline harness can't fetch, so offline Chrome
  also renders full-width; narrowing hb would DIVERGE from the reference. Dropped from roadmap.
- **Round 11 (0abcbf41): borderless-box vertical padding baked at real px** — bordered
  cards/cells were already within 0–4px (rounds 4–10 via `bbox_padv`); the residual ~10–15%
  over-height was plain BORDERLESS padded bands (padding quantised to whole LINE_H rows, fill
  only covering the content row). Extended the real-px padding bbox to borderless blocks+floats
  (no-stroke kind-3 bbox; flex/grid items excluded — they inset via `cur_row` rewind). Fill
  height now within **2px of Chrome** across 4/8/10/12/16px padding. 9/225 fixtures shift, all
  improvements.
- **Heading colour (8cf14fd7): UA-default h1–h6 = body black `#101010`, not `#14306e` blue.**
  USER flagged the Wikipedia render's blue headings as the last major visible diff vs Chrome.
  Chrome's UA stylesheet gives headings no colour (inherit black); hambrowse hardcoded a
  "heading dark blue" in the role palette (`_palette`/`_palette_rgb` idx 2). Set to body text.
  Explicit author `color:` still wins via the cascade (impliedtags fixture's `h2{color:#14306e}`
  unchanged). Gates: host (h1/h2/h4/h5/h6 UA-default assertions → #101010), impliedtags,
  headmargin, google, realsite, realarticle all PASS. Wiki render confirmed black headings.

### Ranked roadmap for round 12+ (in flight: round 12 = HN residual, agent aa4cd81c)
1. **HN residual column geometry** — rank/vote column wider than Chrome (title starts ~150 vs
   ~100px); inline sitebit `(domain)` extra leading whitespace. General table-column lever.
2. **MDN responsive mega-menu collapse** — desktop nav is a click-dropdown Chrome hides; hb
   renders it expanded (media-query `display:none` / CSSOM). Big MDN lever, complex.
3. **Global 1px-per-line line-box over-height** (row pitch 19 vs Chrome ~18.4) — now the
   dominant residual on every multi-line box; HIGH reach but HIGH risk (the BODY_H/LINE_H
   quantisation sticky + grid-auto-rows invariants depend on; needs a per-row variable-pitch
   pass, not a global floor change).
4. `font-family: serif`/`monospace` generic-family selection (low cross-site impact).

## Chrome-parity progress (round 12, main 91080d11)
CLOSED: **`cellpadding="0"` / `cellspacing="0"` honoring** (the HN/forum/aggregator
presentational-table pattern). hambrowse ignored the attribute — every column carried a
fixed 16px CELL_PAD + 6px CELL_PADX and empty cells floored to 24px, so HN's rank +
empty-votelinks columns pushed each story title far right. Now `<table>` open parses
`cellpadding` (new `g_tbl_cpad`/`g_tbl_padx` + stack slots), the column model uses it, and
empty cells collapse when cpad=0. Measured vs chromium (no news.css): full HN page
rank→title **72px → 32px** (Chrome 26); isolated row **56px → 16px** (Chrome 12); empty
votelinks column collapses; page height unchanged (horizontal fix). Churn: exactly 9
fixtures shift (the cellpadding=0 ones), 224 byte-identical, 17/17 required gates PASS. New
gate `test_hambrowse_cellpad0_host.sh` (base title x0=66 FAIL / fix x0=26 PASS, cpad=8
control stays 66). Sitebit `(domain)` leading-whitespace gap 2 measured 16 vs Chrome ~9px —
inline flow, the DejaVu space+`(` glyph advance (font-metric lever), NOT a padding bug.

### Ranked roadmap for round 13+ (in flight: round 13 = HN centering gutter)
1. **HN `<center><table width=85%>` centering gutter** — Chrome indents the whole table
   ~75px (85% of 1000, centered); hambrowse gives ~8px (rank@8 vs Chrome@90). General
   `<center>`/`margin:auto` gutter lever for legacy centered-layout sites.
2. **MDN responsive mega-menu collapse** — media-query `display:none` / CSSOM.
3. **Sitebit / inline space-glyph width** (space+`(` 16px vs Chrome ~9px) — the DejaVu-wide
   space advance; ties into the general font-metric lever affecting all prose.
4. Wikipedia article-column max-width (SSIM 0.826, closest).
