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
  - **NEW residual (open)**: vertical fidelity — google's `calc(100%-560px)` hero heights push the logo/searchbox low + some button overlap bottom-right. Horizontal centering done; `calc()`-based block heights are the next browser gap.
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
