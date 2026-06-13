# DE interactive-perf collapse — diagnosis

Read-only investigation. The user's complaint is real: in fresh
QEMU + OVMF + `-vga std -m 1G` the DE loads, but rubber-band
dragging, menu tracking, and window dragging all collapse to roughly
0.5 Hz; with nothing open the mouse is fast; spurious characters
appear in the focused shell while a window is being dragged. This
report cites file:line, names the root causes, and ranks the fix
list. **No code edits applied.**

All cites are against this worktree (branched off `3be73f8d`).

---

## Headline: top 3 root causes

1. **Every drag / rubber-band / resize / context-menu frame falls
   through `damage_full()` → `daemon_present()` → `scene_build_full()`,
   which re-runs the procedural `daemon_pixel` over every pixel of
   the framebuffer. `daemon_pixel` is a ~1.3 KLoC chained cascade
   walking wallpaper, every desktop icon, every window, every
   widget, the rubber band, the panel, every applet, the calendar,
   the run dialog, the cycler, the menu — once *per pixel*. The
   #410 SCENE_CACHE is thrown away every frame the user is
   interacting.** This is THE bottleneck. Fixing it (per-state
   incremental damage instead of `damage_full`) recovers an
   order or two of magnitude before any other change.
2. **The software cursor is on the same critical section as full
   scene rebuilds.** The "cursor MUST render independently of
   compositor work" architectural call in `TODO.md` lines 25–26
   is not satisfied. `daemon_present_cursor_move` (the cheap
   12×12 blit) only runs when `daemon_flush_damage()` returned 0
   — and during drag/menu we ALWAYS damage-full, so the cheap
   cursor path never fires while the user is interacting. The
   cursor's apparent freeze is just the compositor blocking on
   a full per-pixel pass.
3. **Spurious keystrokes during drag come from `key_route()`
   (user/hamUId.ad:25294) not being gated on drag/menu state**:
   `daemon_pump_keys` (user/hamUId.ad:25702) unconditionally drains
   `/dev/cons` every frame and delivers every byte to
   `daemon_focus_slot()` (the topmost window). Because frames are
   ~2 s apart during drag, accumulated keystrokes (whatever the
   user typed before the drag, late autorepeat, or noise from the
   PS/2 controller drift) arrive in one burst into the dragged
   shell. There is no per-frame "drag absorbs/discards keys" gate
   and no key-up/key-down filtering — `key_route` blindly
   re-emits every byte both to the wsys event file
   (`evt_emit_key`, line 25307) and the child's stdin pipe
   (line 25351).

The three root causes compound: a slow frame stretches the
keystroke-burst window AND keeps the cursor frozen.

---

## 1 · Compositor main loop — per-frame cost during drag

Loop entry: `daemon_frame()` (user/hamUId.ad:25885). Order of work
per wake:

| Step | Function | File:Line | Cost during drag |
| ---- | -------- | --------- | ---------------- |
| 1 | `damage_reset()` | 25891 | O(1) |
| 2 | `daemon_pump_mouse` | 25892 → 13123 | Reads /dev/mouse, parses packets, updates CUR_X/Y, evaluates 14× scene-mutation flags. Sets `MOUSE_SCENE_DIRTY=1` whenever `lbtn!=0 OR DRAG_ACTIVE OR RESIZE_SLOT>=0 OR menu/popup open` (line 13249). |
| 3 | `daemon_pump_keys` | 25895 → 25702 | Drains /dev/cons, routes every byte through `key_route` to focused window. **NOT gated on drag state.** |
| 4 | `daemon_pump_terms` | 25910 → 25719 | Drain each window's stdout. |
| 5 | `evl_poll_markup` | 25917 → 25767 | Per-layer gen counter probe — cheap. |
| 6 | `if MOUSE_SCENE_DIRTY: damage_full()` | 25927 | **Whole-screen damage.** Set on every motion packet during drag. |
| 7 | `if DRAG_ACTIVE: damage_full()` | 25943 | Redundant: already covered above. |
| 8 | `if KMODE: damage_full()` | 25949 | Whole-screen damage. |
| 9 | `daemon_flush_damage()` | 26050 → 12284 | If DMG_FULL: `daemon_present()` → `scene_build_full()` (12064 → 11985) — single full pass of `daemon_pixel` over the whole framebuffer. |
| 10 | else if `cursor_moved`: `daemon_present_cursor_move` | 26051 → 12182 | **Only runs when nothing damaged the scene.** During drag step 6 always wins, so the cheap cursor blit is *unreachable*. |

The per-pixel cost lives in `daemon_pixel` (10536–11803, **~1267
lines** between its `def` and the next top-level `def
cursor_pixel_over` at 11810). A small sample of what runs *per
pixel*:

- wallpaper sample test (10545–10558)
- `while di < DICON_COUNT` desktop-icon scan (10561+)
- ROUND-19 desktop sysmon applet
- per-window back-to-front composite walk into `window_render_self`
- title-bar button hit-tests
- the rubber-band edge test (11395–11407) — **every pixel checks
  whether it sits on the rubber-band rectangle outline**
- calendar popup (CAL_OPEN, 11408+)
- run-dialog overlay (11758+)
- panel/clock/taskbar/tray (further down)
- alt-tab cycler popup
- menubar / context menu cascade
- snap-preview translucent fill

Each branch is cheap on its own; in aggregate, at 1024×768 = 786 432
pixels, the procedural path is multiple-hundred-million-operation
work per frame. With `KVM -cpu host`, an unoptimised Adder build of
that walk is plausibly the observed ~2 s per frame.

### #409 per-window backbuffer cache — present but small-window only

`WCACHE_*` (user/hamUId.ad:8773–8801) caches a per-window surface
**only if** `DWIN_W <= 400 AND DWIN_H <= 300` (`window_cacheable`,
10424–10434). A default terminal is wider than that. **Anything
maximised, half-snapped, or larger than 400×300 falls back to the
procedural per-pixel path inside `daemon_pixel` every frame.** So
the #409 cache does not help precisely the windows the user is
dragging.

### #410 SCENE_CACHE — present but invalidated every interactive frame

`SCENE_CACHE` (user/hamUId.ad:8786, 8 MiB RGBA full-screen) holds
the cursor-free composited scene. `scene_build_full` (11985) fills
it via one whole-screen `daemon_pixel` walk; `scene_build_rect`
(11951) is a damaged-rect refill; `scene_blit_rect` (11996) is the
"cheap" present that just copies cache bytes to /dev/fb.

During the symptoms the user reported:

- Rubber-band drag: `DRAG_ACTIVE=1` → main loop hits
  `damage_full()` at 25944 → `daemon_present()` → `scene_build_full()`
  — the whole cache is rebuilt every frame.
- Title-bar window drag: `GESTURE=1, MOVE_SLOT>=0, lbtn=1` →
  `MOUSE_SCENE_DIRTY=1` (13249) → `damage_full()` (25927) → same
  full rebuild.
- Menu tracking with menu open: `MENU_BAR_OPEN>=0` or `CTX_OPEN>=0`
  → `MOUSE_SCENE_DIRTY=1` every motion packet (13249) → same full
  rebuild.

So `SCENE_CACHE` is correctly designed but its benefit applies only
to the *non-interactive* path. Once the user touches a button,
every frame is a full rebuild. **The 100× #410 perf claim was
measured against pure cursor moves and damage-bounded partial
presents — not against the interactive ("button held") regime.**

---

## 2 · Per-pixel vs cached-blit accounting

| Path | When it runs | Cost |
| ---- | ------------ | ---- |
| `daemon_present_cursor_move` (12182) | nothing was damaged AND cursor moved | 2× 12×12 blit from SCENE_CACHE — ideal |
| `daemon_present_rect` (12106) | partial damage union (window content change, hover, banner fade) | `scene_build_rect` over that rect, then `scene_blit_rect` |
| `daemon_present` (12064) | `DMG_FULL` set, or workspace switch | `scene_build_full` — **full-screen daemon_pixel** |

During the user's slow regime, *every* frame goes through path 3.
SCENE_CACHE never gets reused: it is overwritten as fast as it
would be read.

Inside `daemon_pixel` the `window_render_self` call for a window
that doesn't fit the 400×300 cap re-runs the window's *own* per-pixel
render every screen pixel that lands inside it — the cost
multiplies with window area, not with cached-surface size.

---

## 3 · Cursor render path — is it on the same critical section?

Yes. There is a fast path (12153 `scene_blit_cursor_cell`) that
costs 288 pixels for the whole move. It is reached only via
`daemon_present_cursor_move` (12182), which the main loop calls
**only if `daemon_flush_damage()` returned 0** (line 26050). When
the user is dragging, `daemon_flush_damage()` always returns 1 (full
scene present), so the cheap cursor path never fires while the user
is interacting.

The cursor sprite is rendered:

- in `scene_blit_rect` via `cursor_pixel_over` (11810) — overlaid
  on the wire bytes during the scanout copy of *any* damage flush.
- in `scene_blit_cursor_cell` (12153) — the dedicated fast path.

There is **no separate hot path that paints the cursor independent
of the compositor**. The architectural directive in TODO.md
"Mouse cursor MUST render independently of compositor work" is not
yet implemented. The cursor cell is a 12×12 sprite — it could run
from a separate task that simply writes the sprite + restores the
under-pixels to /dev/fb directly, but right now it shares the
present pipeline with the full scene.

---

## 4 · Spurious-keystroke-on-drag — exact mis-stitch

Pipeline:

1. `daemon_frame` (25885) calls `daemon_pump_keys` (25895)
   *unconditionally* every wake — no `if DRAG_ACTIVE` /
   `if MOUSE_SCENE_DIRTY` gate.
2. `daemon_pump_keys` (25702) drains /dev/cons via
   `sys_read_nb`, up to 256 bytes × 4096 iterations per frame —
   a slow ~2 s frame is plenty of time for autorepeat / user
   "is it stuck? let me type" buffer to accumulate.
3. The bytes are routed through `key_process_chunk` (25377) →
   `key_route` (25294), which:
   - emits one wsys "d <code>" press event per byte
     (`evt_emit_key`, 25307) — every byte becomes a
     **down**-only event with no up.
   - writes the byte to the focused window's child-stdin pipe
     (`sys_write(wfd, ...)`, 25351) with a spin-retry loop bounded
     at 4096 yields (25358).
4. `daemon_focus_slot()` (25237) returns "topmost window" =
   `DWIN_COUNT-1`. The dragged shell is by definition topmost
   during a drag, so every queued byte lands in it.

Three independent defects in this stitch:

- **Defect A (latency-amplified):** with a ~2 s frame, the byte
  burst the user "doesn't see typing" gets delivered as one fat
  blob at the next wake — and lands in the focused shell.
- **Defect B (drag should swallow keys):** there is no
  intentional gate of `key_route` while a pointer drag is
  in-flight. MATE/GNOME swallow most keystrokes during an active
  pointer-grab; this WM does not.
- **Defect C (key-up never emitted):** `evt_emit_key` is only ever
  called with `etype=100` ('d' press) at 25307. There is no 'u'
  release. Markup clients that try to track modifier state will
  latch the modifier forever. (Not the immediate symptom but the
  same code site.)

A fourth, more speculative possibility: the PS/2 controller
detects "no reader" on /dev/cons during the long frame and surfaces
a "make/break" or autorepeat byte on the next read; the spin-bounded
write loop on a saturated child pipe (25350–25361) re-enters
`sys_yield` and that yield is sometimes the only chance for an IRQ
to fire — masking a self-amplifying loop. Worth a look once the
main per-frame cost is fixed.

---

## 5 · What's drawn with raw primitives vs through lib/hamui.ad

The compositor itself (`user/hamUId.ad`) **never calls into
`lib/hamui.ad`**. `lib/hamui.ad` is a *client-side* toolkit: it
emits "ui" markup (widget tree, label/button/list/menu/...) that
client processes write into their wsys layer. The compositor then
*reads* that markup (`rasterise_markup`, 1431) when it composes the
window body.

Painted by raw `daemon_pixel` (user/hamUId.ad:10536) per-pixel
cascade:

- root backdrop (10538–10540)
- wallpaper PPM sample (10545–10558)
- desktop icons (10561+)
- desktop sysmon applet
- panel band, taskbar buttons, clock, tray, system-notifier icons
- menubar, classic menu, context menus, sub-menus
- alt-tab cycler popup
- calendar dropdown
- run-dialog
- session/lock screensaver overlays
- snap-preview, magnet edges
- **rubber-band outline** (11395)
- **cursor sprite** (now via `cursor_pixel_over` 11810 inside
  `scene_blit_rect` — composited on the wire, not in SCENE_CACHE)
- per-window frame chrome (border, title, close/min/max buttons)

Painted via `window_render_self` (also raw — title text, frame,
client body buffer or markup composite):

- window decoration
- client body — either the markup raster (from
  `daemon_markup_read_body` 2108) when the client used hamui, or
  the built-in widget body (calculator, file manager, editor).

So: every visible primitive on screen is raw-drawn. Toolkit usage
exists only at the *client* end, and only for clients that bothered.
The architectural direction in TODO.md item 2 ("Panels and apps
render through `lib/hamui.ad`, NOT raw primitives") is not the
state of the world today.

`sys/src/9/port/devwsys.ad` is the kernel-side `#w` file server:
it owns per-window layer files (`draw/ui`, `draw/fb`, `keys`,
`pointer`, `geom`, `opacity`, `ui/gen`, `text`, etc.). It does not
do drawing — it stores bytes and wakes readers. Input pipeline
on the kernel side feeds `evt_emit_key`-shaped events into per-window
keys files; the compositor is the only writer to those.

---

## 6 · Reconciling #430 (100× cached-layer perf) vs #441
   (interactive latency in_progress)

`#410` (commit `6d769feb`, "DE perf #410: cached-layer blit
compositor") landed the SCENE_CACHE machinery. The commit message
states three specific defects it fixes: window-open path no longer
calls `damage_full`, markup body reads gated behind MARKUP_DUE, and
the cursor-move path is cache-only. Those three are real fixes and
in tree.

What `#410` did **not** address — and what `#441` (commits
`b18ce889`, `58cdb4f0`, `c7807500`, branched "fix 1/4..3/4",
title "interactive-latency deep-dive") is partially attacking:

- Whole-screen `damage_full()` on every motion packet during drag
  / resize / menu (line 13249 condition is very broad).
- The 400×300 WCACHE cap (8773–8774) leaves any reasonable terminal
  in the procedural per-pixel branch even when not interacting.
- The 1.3 KLoC per-pixel cascade in `daemon_pixel` itself —
  irrespective of caching, it touches every pixel of every
  `scene_build_rect` call.

The user's tested scenario (drag, menu) is exactly the
"interactive" regime that #410 explicitly does not optimise.
**The 100× claim was real for the cases #410 measured (window-open,
cursor-only-move, markup gen-tick) — not for the drag/menu regime
the user is now hitting.**

---

## Prioritized fix list — agent dispatches

Order top-down by expected user-visible impact.

### P0 — recover an order of magnitude on drag/menu

**P0-A. Detach the cursor from the compositor critical section.**

Dispatch agent: small, surgical.

- Maintain a small "cursor under" backing store (12×12 RGB) sampled
  from SCENE_CACHE at every full or partial present.
- On each `daemon_pump_mouse` motion (not gated on damage state),
  if the cursor moved AND SCENE_CACHE is valid, write the old-cell
  bytes (under-store) then the new sprite straight to /dev/fb via
  the SAME `fbctl_present_rect` fast-path. Do this BEFORE returning
  from `daemon_pump_mouse`, not at end-of-frame.
- This makes cursor latency O(2×144 pixels) per motion packet,
  independent of any later damage_full pass. Even if the
  compositor takes 2 s to recompose, the cursor tracks fluidly.

Cite anchor: insert the new cursor "shadow blit" between
`daemon_pump_mouse` (user/hamUId.ad:25892) returning and the rest
of frame work. Reuse `scene_blit_cursor_cell` (12153) as the
mechanic.

**P0-B. Stop full-screen damaging on every motion packet during
drag/menu.**

Change `if MOUSE_SCENE_DIRTY: damage_full()` (user/hamUId.ad:25926
–25928) and the gating at 13242–13254 to:

- **window-move drag (GESTURE=1 + MOVE_SLOT>=0):** damage_full() →
  damage union of (old window rect, new window rect). The window
  surface cache is unchanged; only its offset moved. The 400×300
  WCACHE cap should also be raised so the dragged window stays
  cached. (See P1-A.)
- **rubber-band (DRAG_ACTIVE=1, MOVE_SLOT<0):** damage union of
  (old rubber-band bbox, new rubber-band bbox). The rubber-band
  outline is 1-pixel-thick, so this is O(perimeter), not O(area).
  Move the rubber-band-edge test OUT of `daemon_pixel` (11394
  –11407) so it does not run for every screen pixel. Paint it as
  a post-pass overlay in `scene_blit_rect` instead.
- **context menu / menubar / cycler / calendar / run-dialog
  open:** damage only the popup bbox + the previous-frame popup
  bbox (for hover transitions), not the whole screen.
- **resize (GESTURE=4):** damage the window's old bbox ∪ new bbox.

**P0-C. Gate keystroke delivery to the focused window while a
pointer drag is in flight.**

Edit `daemon_pump_keys` (user/hamUId.ad:25702) so that when
`DRAG_ACTIVE != 0 OR MOVE_SLOT >= 0 OR RESIZE_SLOT >= 0`, drained
bytes are *parked* (not delivered) — and dispatched at the next
button-release frame OR discarded if the user hit Escape. (MATE's
behaviour is closer to "discarded"; either is a strict improvement
over "delivered as a fat burst into the dragged shell".)

Belt-and-braces: emit both 'd' (press) and 'u' (release) events
from `key_route` (25307) so wsys clients see a paired event stream.

### P1 — un-cap the per-window cache and stop the per-pixel cascade

**P1-A. Raise the WCACHE per-window cap from 400×300 to at least
1600×1200** (user/hamUId.ad:8773–8776 and the `WCACHE_RGB` array
size at 8776). Memory math: 8 slots × 1600 × 1200 × 3 = ~46 MiB —
acceptable. A maximised terminal currently misses cache; this gets
it cached and pure window-move drag becomes O(window-rect blit
from cache), no `window_render_self` per pixel.

**P1-B. Hoist the rubber-band edge test out of `daemon_pixel`** as
an overlay pass in `scene_blit_rect` (user/hamUId.ad:11996). The
band is a 1-pixel-thick rectangle outline; an O(perimeter) overlay
loop is dramatically cheaper than an O(screen) per-pixel branch.

**P1-C. Slice `daemon_pixel`** (10536–11803) into stage-keyed
helpers (`pixel_root`, `pixel_window`, `pixel_panel`, `pixel_popup`,
...) so a `scene_build_rect` confined to e.g. the menu popup bbox
runs only `pixel_popup` for those pixels, not the full
1.3-KLoC cascade. Big-bang OK per the project's "big-bang ok for
base" preference.

### P2 — bring lib/hamui.ad into the compositor itself

Architectural direction from TODO.md item 2. After P0/P1 are
green, refactor the compositor's panel, menus, cycler, calendar,
run-dialog, and chrome to issue toolkit-shape markup and have the
compositor consume it through the same `rasterise_markup` path the
client windows use. That gets damage tracking and caching uniformly
for the WM's own widgets too.

### P3 — track #181-185 Vulkan spine for software rasteriser

Memory item: north-star is software-rasterised Vulkan path. After
P0/P1 land and the design is stable, point `scene_blit_rect` at a
software-Vulkan path so each present is a buffer-handoff rather
than a CPU memcpy + /dev/fb write. Lowest priority — only worth it
once the interactive regime is fast on the CPU path.

---

## Don't bother — looks suspicious, isn't a hot path

- **`evl_poll_markup`** (25767): pure gen-counter reads, one per
  visible window, gen-gated. Not on the hot path.
- **`markup_sync`** (2174): expensive markup-body reads are
  gated behind MARKUP_DUE per the #410 fix; not contributing
  to the drag-frame cost.
- **`window_cache_sync`** (10479): a pure-move drag does NOT set
  `DWIN_CONTENT_DIRTY` (10516–10519, asserted in 10500), so the
  cache is reused. Hands-off on a move.
- **`/dev/fb` writes via `sys_lseek`+`sys_write`**
  (12044–12057): the partial-row path is already
  damage-bounded; full-screen writes use a contiguous
  `fbctl_present_rect` (11898) via the persistent `fbctl_fd`.
  Not the bottleneck.
- **`daemon_pump_mouse` packet parse** (13123): O(packets/frame).
  Cheap.
- **PS/2 vs USB-tablet routing** (drivers/usb/hid.ad,
  drivers/input/auxmouse.ad): kernel-side, IRQ-driven, and
  unchanged from when the mouse is fast (nothing open). Not the
  cause of the drag-time stall.
- **`daemon_pump_terms`** (25719): a busy shell only damages its
  own window rect (25731), which is correct.
- **Adaptive `evl_timeout_ms`** (25836): during drag returns
  `EVL_TIMEOUT_ANIM_MS` (drives a tight wake cadence). The loop
  is not stuck in a long park — it's stuck inside the per-frame
  per-pixel cascade.

---

## Summary cite map

- Main loop: `user/hamUId.ad:25885-26065` (`daemon_frame`)
- Full-recompose trigger during drag: `user/hamUId.ad:25927,25944`
- Per-pixel scene cascade: `user/hamUId.ad:10536-11803`
  (`daemon_pixel`, ~1267 lines)
- Rubber-band edge test inside per-pixel cascade:
  `user/hamUId.ad:11394-11407`
- SCENE_CACHE rebuild on full present:
  `user/hamUId.ad:11985,12064,12079`
- Cursor fast path (only reachable when no damage):
  `user/hamUId.ad:12182-12198, 26050-26051`
- Per-window backbuffer 400×300 cap:
  `user/hamUId.ad:8773-8776, 10424-10434`
- Mouse-packet "scene-dirty" condition (too broad):
  `user/hamUId.ad:13242-13254`
- Keystroke delivery during drag (no gate):
  `user/hamUId.ad:25294-25362, 25702-25714`
- Press-only key events (no release):
  `user/hamUId.ad:25307, 13075-13094`
- Toolkit (clients only):
  `lib/hamui.ad:440-737`
- Kernel wsys input/event server:
  `sys/src/9/port/devwsys.ad`
- #410 cached-layer landing: commit `6d769feb`
- #441 in-progress interactive deep-dive commits:
  `b18ce889`, `58cdb4f0`, `c7807500`
