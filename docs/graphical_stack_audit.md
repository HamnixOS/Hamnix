# Graphical stack architecture audit

Read-only audit. The question: are we polishing an architecturally
wrong path, or is the current shape just under-tuned? If polishing the
wrong path, what is the right path, and when do we pivot?

This is a brutal-honesty grade, not a celebration. File:line cites
are against this worktree (branched off `0c6b3af4`).

---

## Headline recommendation (one sentence)

**Stop polishing the monolith — the current shape is structurally
wrong for the load it carries; finish the rio-faithful #442 (c)
blit protocol and make it THE compositor; keep the native Vulkan
spine as Phase-2 hardware-accel work, not a near-term pivot.**

So: pivot, but stage it as **(P0-B damage-clip) → (#442 (c) blit
protocol = new compositor) → (toolkit-as-base panels/menus) → (Vulkan
spine for accel).** Status-quo P0 work earns runway for the move; it
does not earn a destination.

---

## What the current stack actually is

| Piece | File | LOC | Shape |
| ----- | ---- | --- | ----- |
| Compositor / WM / panel / apps | `user/hamUId.ad` | 27 289 | Single-process monolith. Owns fb writes, input pump, focus, window layout, panel, menus, every applet, the calendar, the run dialog, the cycler, AND per-pixel rendering of every visible primitive. |
| Toolkit | `lib/hamui.ad` | 3 713 | Client-side retained-mode widget tree. Emits hamML markup; consumed by the compositor's `rasterise_markup`. Used by hamterm/hamcalc/hamclock/hamview/etc. NOT used by the compositor itself. |
| Kernel window server | `sys/src/9/port/devwsys.ad` | 3 080 | `#w` file server. Stores per-window text/markup/event rings + serial/dirty rect. Spec for the (c) blit protocol is at the TOP of the file (lines 61–98); the parser is **not implemented**. |
| Native Vulkan spine | `lib/vk/*.ad` | 1 800 | Phase 0 LANDED (commit `18361e7`). Real handle types, software rasterizer, present-to-`/dev/fb`. Gated behind `/etc/vk-test`. NOT wired into the DE. |
| Rio-faithful reshape | `616c41c4` (#442) | — | (a) per-process `#w` bind + (b) blocking reads landed. **(c) image+dirty-rect wire format = spec block only.** |

Per the `de_perf_diagnosis.md` cite map: `daemon_pixel` is a
**1267-line per-pixel cascade** (user/hamUId.ad:10536-11803) walking
wallpaper, every desktop icon, every window, every widget, the
rubber band, the panel, every applet, the calendar, the run dialog,
the cycler, and the menu — **once per pixel**. SCENE_CACHE (8 MiB
RGBA) caches the composited frame; per-window WCACHE caches the body —
**but only if the window is ≤ 400×300** (user/hamUId.ad:8788-8791,
10445). A default terminal busts that cap.

That is the floor we are measuring from.

---

## Five architectures, graded

Axes per architecture. Bold = the failing axis.

### 1 · Status quo + P0/P1 tuning (current path)

What it is: keep the monolith. Detach the cursor (P0-A landed
`0f4b2e19`). Damage-clip drag/menu (P0-B in flight). Gate keys during
drag (P0-C landed `a465991f`). Raise WCACHE cap. Slice `daemon_pixel`.

- **Per-frame work**: ONE process composes everything by walking a
  1.3 KLoC procedural cascade per pixel of damage. Even after damage
  clipping, every damaged pixel pays the full cascade unless P1-C
  (slice into stage-keyed helpers) lands. **Zero context switches**
  in the steady state — also means zero parallelism.
- **Cursor decoupling**: NOW decoupled (P0-A) by a 12×12 save-under
  shadow blit running inside `daemon_pump_mouse`. This is a glued-on
  fast-path, not architectural. **It works, but every future hot
  path needs the same kind of bespoke decoupling.**
- **Input routing**: `daemon_pump_keys` drains `/dev/cons`
  unconditionally, hands every byte to `daemon_focus_slot()` =
  `DWIN_COUNT-1` (topmost). No real focus. No click-to-focus. No key
  release events (only 'd' press; see diagnosis §4).
- **Toolkit-as-base**: `lib/hamui.ad` is **not used by the
  compositor itself** (de_perf_diagnosis §5). The compositor
  *consumes* markup but its panel, menus, cycler, calendar, run-
  dialog, chrome are raw `daemon_pixel` cascade. Toolkit is **bolted
  on at the client end**, not the base.
- **Damage tracking**: bolted on. `damage_full()` is the default for
  drag/menu/resize; per-rect damage exists but the trigger logic
  (user/hamUId.ad:13242-13254) is overly broad. The 100× #410 SCENE_-
  CACHE claim was measured against the cases it explicitly does NOT
  cover.
- **Hardware accel path**: writes raw pixels to `/dev/fb` via
  `fbctl_present_rect`. To swap in a Vulkan/i915 present, the entire
  `scene_blit_rect` and `daemon_present` paths get rewritten. The
  toolkit is unaware of any accel.
- **Migration cost from now**: zero (this is current). But every
  optimization is paid against a 27 k-line monolith that grows every
  feature.
- **Bottom-of-barrel risk**: HIGH. At peak P0-A/B/C + P1 + P2 polish,
  drag latency is bounded by `damage_rect × per-pixel-cascade-cost`.
  Even with `daemon_pixel` sliced into 8 helpers, a damaged
  1024×600 window rect on unoptimised Adder is **multi-hundred-
  million-operations** per frame. There is no headroom for: a real
  panel with live applets, animations, font anti-aliasing, theming,
  or anything resembling a modern DE.

**Grade: D**. Polishable to "usable for a static desktop with one
window." Not polishable to "MATE-class DE the user wanted." Every
incremental fix raises monolith complexity without raising the
ceiling.

### 2 · Rio-faithful Plan 9 (finish #442 (c))

What it is: each client process renders to its own backbuffer
(via `lib/hamui.ad` client-side), writes `'B' x0 y0 x1 y1 fmt pixels`
+ `'D' x0 y0 x1 y1` to `/dev/win/draw/ctl`. devwsys stores the
backbuffer + dirty rect. The compositor becomes a **pure blitter**:
walks dirty rects, blits cached backbuffers, draws cursor sprite,
present. No per-pixel cascade. No `daemon_pixel`.

- **Per-frame work**: O(sum of dirty rects). One memcpy per damaged
  client rect from the kernel-held backbuffer into SCENE_CACHE (or
  straight to `/dev/fb` if no overlap). Context switches: one per
  client that actually drew this frame, paid only on writes — the
  compositor wakes on `waitfds` (already wired). **An idle window
  costs ZERO compositor work.** A typing terminal costs one
  rect-blit per keystroke.
- **Cursor decoupling**: TRIVIAL. Cursor is `'C'` verb in the same
  protocol, composited above all windows by the blitter. The save-
  under is one rect, same as P0-A's shim — but it's the architecture,
  not a workaround.
- **Input routing**: per-window `/dev/win/keys`+`/dev/win/pointer`
  already in tree (lib/hamui.ad header). Focus = which `#w` is bound
  to which client; rio gives this for free. Per-window namespace bind
  (`616c41c4` (a)) already kills the "keys leak to /dev/cons" class.
- **Toolkit-as-base**: NATURAL. Every client (panel, menus, terminal,
  apps) is a `lib/hamui.ad` process. The panel becomes a hamui
  process. The classic-menu becomes a hamui process. The cycler
  becomes a hamui process. The compositor never knows what a button
  is.
- **Damage tracking**: NATIVE to the protocol — the `'D'` verb IS
  damage. No bolt-on.
- **Hardware accel path**: the blitter is the only consumer of pixels.
  Swap `scene_blit_rect` for a Vulkan vkCmdBlitImage + vkQueuePresent;
  every client benefits with no client changes. Vulkan spine plugs
  in cleanly at exactly one seam.
- **Migration cost from now**:
  - `user/hamUId.ad` 27 289 LOC: roughly **8–12 k LOC survives** as
    the new blitter + cursor + window-frame chrome + WM gestures
    (move/resize/snap/menu-tracking-as-IPC). The other ~15 k LOC of
    raw-primitive applets/panel/menus/calendar/run-dialog gets
    REWRITTEN as separate hamui clients (each 200–500 LOC).
  - `lib/hamui.ad` 3 713 LOC: **survives nearly verbatim**; gains a
    client-side rasterizer (~600 LOC: rect/line/text → backbuffer
    bytes, feeding `'B'` verb).
  - `sys/src/9/port/devwsys.ad` 3 080 LOC: gains a `'B'/'D'/'C'`
    parser + per-window backbuffer storage (~400 LOC). Spec already
    in the file.
  - Apps: hamterm/hamcalc/hamclock/hamview/hammon already are hamui
    clients; **they unchanged**. Add hamui apps for panel/menus/
    calendar/run-dialog/cycler.
  - **Agent-weeks: 4–6 disjoint dispatches over 1–2 weeks of
    wall-clock.** (a) protocol-parser + per-window backbuffer
    storage; (b) client-side rasterizer in hamui; (c) compositor
    blitter rewrite; (d) panel-as-client; (e) menus/popups-as-
    clients; (f) chrome+WM gestures.
- **Bottom-of-barrel risk**: LOW. Floor latency is `dirty-rect-area
  × memcpy-bandwidth`. A 1024×600 window damage at 8 GB/s is
  ~230 μs. That is 4 kHz of headroom. We are bottoming out at
  hardware bandwidth, which is the right floor.

**Grade: A−**. The minus is because the (c) protocol is still
spec-only and "we have a spec at the top of devwsys.ad" has been
true for two days. Implementing it is real work, not a paper move.

### 3 · Wayland-shape

What it is: SHM-buffer handoff. Clients allocate shared-memory
buffers, fill them, send a buffer-handle + damage rect to the
compositor over a unix socket (or in our case, a 9P file). The
compositor composes from the SHM buffers.

- **Per-frame work**: Same shape as rio-faithful — O(dirty rect),
  one memcpy per damaged region. Marginally cheaper than (2) on the
  hot path (no kernel-side buffer storage; client owns the SHM).
- **Cursor decoupling**: trivial (`wl_pointer` + cursor surface). Same
  as (2).
- **Input routing**: per-surface focus, modern. Same shape as (2)
  with more protocol surface.
- **Toolkit-as-base**: natural — every Wayland client uses a toolkit.
  Same as (2).
- **Damage tracking**: native to the protocol. Same as (2).
- **Hardware accel path**: this is where Wayland was designed to
  win — DMA-BUF handoff to the GPU. **We don't have DMA-BUF.** We
  have `/dev/fb` and a software rasterizer. The accel advantage is
  zero until #182-#184 land.
- **Migration cost**: SAME survival numbers as (2), PLUS a SHM
  allocator (we don't have one), PLUS a buffer-management protocol
  (wl_shm + xdg-shell shapes), PLUS we're inventing a Wayland-on-9P
  hybrid that nobody else has built. **Agent-weeks: 8–12.**
- **Bottom-of-barrel risk**: LOW (same as 2).

**Grade: B**. Slightly cleaner accel story than (2), but we pay
the protocol-design cost AND we abandon the Plan 9 ethos for no
architectural win at this scale. **Wayland is rio with NIH + DMA-BUF.
We have rio. We don't have DMA-BUF.** Wrong trade.

### 4 · X11-shape

What it is: server owns the window tree and the draw context.
Clients send draw ops (XDrawLine, XPolyFillRect, XCopyArea, font
glyph IDs) over a wire. Server rasterizes.

- **Per-frame work**: server pays the rasterization cost per op,
  per client. Without GPU acceleration (XAA / EXA / Glamor), this is
  *worse* than (1) — every client draws on the server thread.
- **Cursor decoupling**: hard. The X server's cursor is part of the
  same draw context.
- **Input routing**: server-side, server-imposed focus model.
- **Toolkit-as-base**: irrelevant — clients still use toolkits, but
  the toolkit calls into Xlib draw ops, not into a damage protocol.
- **Damage tracking**: bolted on (XDAMAGE extension).
- **Hardware accel path**: this is what made X11 actually work for
  20 years (XAA/Glamor/DRI). We don't have it. **Without GPU accel
  X11's server-side rasterization is a millstone.**
- **Migration cost**: enormous. We'd be writing an X server.
  Xvfb-in-linux-ns is already used for X11 *clients* (H-§C); writing
  our own X server is a multi-month sink with no payoff.
- **Bottom-of-barrel risk**: HIGH. Same per-pixel rasterization
  ceiling as (1), but spread over a wire protocol.

**Grade: F**. Don't.

### 5 · Native Vulkan spine NOW (accelerate #181-185)

What it is: DE composites through the native Vulkan spine
(`lib/vk/`). Compositor uses VkCommandBuffer record/replay; clients
render into VkImages; vkQueuePresent → `/dev/fb`. Today that's all
software-rasterized; later #182 (virtio-gpu+venus), #184 (i915.ko)
add real hardware.

- **Per-frame work**: software-rasterized Vulkan is **strictly
  slower than memcpy blitting today** because every present routes
  through vk_raster.ad's triangle-setup + half-plane edge functions
  + barycentric interp. Vulkan's value is the cmd-buffer record/
  replay abstraction that lets a future GPU run the same buffers.
  Today, on `lib/vk/vk_raster.ad` (361 LOC), it's a triangle
  rasterizer — not a blitter — and it's slower than the path we
  have.
- **Cursor decoupling**: trivial via VK_KHR_swapchain layering.
- **Input routing**: orthogonal — Vulkan doesn't dictate input.
- **Toolkit-as-base**: orthogonal — toolkit can still emit
  hamui markup; the rasterizer changes.
- **Damage tracking**: VK_KHR_swapchain present-regions exists but is
  not the natural shape; you'd build a damage protocol ON TOP of
  Vulkan, which is exactly what (2) and (3) already are.
- **Hardware accel path**: the ENTIRE point. When #184 lands and
  i915.ko drives real silicon, every present becomes free.
- **Migration cost**: high *prematurely*. The Vulkan spine is the
  RIGHT BACKEND for (2)'s blitter and for the post-MVP DE, but it is
  **not the right protocol** between clients and compositor. Clients
  rendering directly with vk_raster would need a per-client Vulkan
  context — fine on hardware, but on the CPU rasterizer today it's a
  loss. Agent-weeks: 3–4 to wire compositor presents through vk;
  zero user-visible perf win until #184 ships silicon accel.
- **Bottom-of-barrel risk**: LOW once #184 lands. HIGH if we
  pivot to it now and have to wait for hardware.

**Grade: B+ as a Phase-2 destination, D as a "do it now" move.**
The Vulkan spine is the RIGHT presenter for whatever protocol we
land — but the protocol decision (rio-faithful vs Wayland-shape vs
X11) is independent of the presenter decision. Choose (2) for the
protocol AND (5) for the presenter.

---

## Ranked findings

### Finding 1: The monolith's per-pixel cascade is an architectural
dead-end, not an optimization target.

- `daemon_pixel` is 1267 lines of branchy code (user/hamUId.ad:
  10536-11803). It is called per damaged pixel.
- Even with P0-B damage-clipping, P1-A WCACHE-cap-raise, and P1-C
  cascade-slicing, the work-per-pixel is far above memcpy.
- The architectural commitment to "compositor draws every visible
  primitive itself" forces every new feature (animation, theming,
  AA fonts, fancy applets) into the cascade.
- **This is the bottom of the barrel.** Polishing it further
  has rapidly diminishing returns and growing complexity cost.

### Finding 2: The compositor doesn't use its own toolkit.

- `lib/hamui.ad` exists (3 713 LOC) and is mature enough that
  hamterm/hamcalc/hamclock/hamview/hammon/hamedit/hamsnake/ham2048
  are real apps written on it (per recent commits).
- The compositor's panel, menus, cycler, calendar, run-dialog,
  chrome, applets are all hand-coded inside `daemon_pixel`.
- TODO item 2 ("Panels and apps render through `lib/hamui.ad`, NOT
  raw primitives") IS NOT THE STATE OF THE WORLD (de_perf_diagnosis
  §5, line 267).
- **The toolkit is a satellite, not the spine. That is upside-down.**

### Finding 3: The rio-faithful (c) protocol is DESIGNED but NOT
SHIPPED. Two months of architectural intent are sitting unimplemented
at devwsys.ad:61-98.

- The spec block is correct, complete, and small. It specifies the
  exact wire format, the version-2 negotiation, and the path of
  least migration disruption (v1 widget-tree stays valid; clients
  opt in).
- Every DE-perf round since #410 has hit the same wall: the
  monolith is too coupled to make damage tracking work cleanly.
- (a) and (b) of #442 are LANDED (per-process `#w`, blocking reads
  via WaitQueue). **(c) is the keystone. Until it lands, every
  performance fix is a workaround.**

### Finding 4: The cursor-decoupling problem is a CANARY for the
whole architecture.

- The user has been complaining about "cursor must render
  independent of compositor work" for weeks. P0-A landed (commit
  `0f4b2e19`) and added a save-under shadow blit shim inside
  `daemon_pump_mouse`.
- It works for the cursor. **It will NOT generalize.** Every future
  hot path (menu hover, drag preview, focus highlight, animation
  frame) will need its own bespoke decoupling shim.
- In the rio-faithful shape, ALL of these are free — they are
  separate clients with their own dirty rects.

### Finding 5: The native Vulkan spine is correctly scoped as
Phase 2 hardware-accel, NOT a near-term protocol change.

- `lib/vk/*.ad` (1800 LOC) is real, tested, gated behind
  `/etc/vk-test`. Phase 0 LANDED (`18361e7`).
- Software-rasterized Vulkan is slower than a memcpy blitter today.
- Vulkan becomes the right presenter once #182 virtio-gpu+venus
  lands (VM accel) and especially once #184 i915.ko drives real
  silicon. **That is months away and metal-only.**
- DO NOT conflate "presenter backend" with "client-compositor
  protocol." (2) is the protocol decision; (5) is the presenter
  decision. They compose cleanly.

### Finding 6: We do NOT need Wayland. We do NOT need X11. We have
rio.

- Wayland is what you build when you don't have Plan 9. We have
  Plan 9.
- X11 is what you build when you have hardware accel for server-
  side rasterization. We don't.
- The rio model — per-process namespace bind to a window, blit
  protocol over file ops, kernel as thin broker — is the model
  Hamnix is ALREADY committed to (memory: project_plan9_pivot,
  project_north_star, project_namespace_purity_mandate).
- Switching to Wayland-shape would cost agent-weeks AND betray the
  ethos AND deliver no architectural win we don't already have.

---

## Migration plan if we pivot (recommended)

**Stage A — keep current path alive (1–2 days, in flight).**
- P0-B damage-clip (sibling agent, in flight). Lands.
- This earns 2–4× perf headroom on the current path while we
  build the new one. Don't sink more than P0-B into the monolith.

**Stage B — ship #442 (c) blit protocol (4–6 agent-weeks,
parallelizable into 3–4 disjoint dispatches).**
1. Kernel: `'B'/'D'/'C'` verb parser + per-window backbuffer
   storage in devwsys.ad. (~400 LOC. Spec is in-tree already.)
   Agent 1.
2. Toolkit: client-side rasterizer in `lib/hamui.ad`. Rect/line/
   text/glyph → backbuffer bytes; emits `'B' + 'D'`. (~600 LOC.)
   Agent 2.
3. Compositor: gut `daemon_pixel`. New `daemon_blit` walks dirty
   rects, blits cached backbuffers from kernel via `/dev/win/back`,
   composites cursor sprite via save-under, presents. (~2 000 LOC
   added, ~15 000 LOC of `daemon_pixel`+applets DELETED net.)
   Agent 3.
4. Apps: port panel + classic-menu + cycler + calendar + run-
   dialog + screensaver + lock to hamui clients. (5–8 small apps,
   200–500 LOC each.) Agent 4 (or queue of small agents).

**Stage C — toolkit-as-base (concurrent with B.4).**
- The DE rewrite per `project_de_mate_mirror_rewrite` is the
  natural shape now: each MATE component becomes a hamui-client
  process. Increments 1 and 2 already landed (hamecho, hamterm
  separate processes); continue the pattern.

**Stage D — wire the Vulkan spine as the presenter (post-MVP, 3-4
agent-weeks).**
- After Stage B is live, replace `scene_blit_rect`'s `/dev/fb`
  writes with vkCmdBlitImage + vkQueuePresent. Toolkit and clients
  unchanged. Same software output today; hardware-accelerated when
  #184 lands.

**What survives. Migration cost in three bullets:**

- **`lib/hamui.ad` (3 713 LOC):** survives nearly verbatim, gains
  ~600 LOC client-side rasterizer.
- **`user/hamUId.ad` (27 289 LOC):** ~8 000 LOC of WM/chrome/
  gesture/focus/spawn machinery survives; **~15 000 LOC of
  `daemon_pixel` cascade + panel + applets + popups + dialogs is
  deleted** and re-emerges as ~3 000 LOC across 6-8 hamui-client
  apps.
- **`sys/src/9/port/devwsys.ad` (3 080 LOC):** spec already in
  tree; +400 LOC parser, +per-window backbuffer storage. No
  protocol invention needed.

Total **net deletion** on the order of 10 000 LOC. This is the
correct sign for a pivot: we are removing complexity, not adding it.

---

## Brutal-honesty close

We are not just "scraping the bottom of the barrel" — we are
polishing the BOTTOM of the barrel while a finished blueprint for a
better barrel sits at the top of `devwsys.ad`, written by us, dated
two days ago.

P0-A (cursor decouple) and P0-B (damage clip) are the right tactical
moves to keep the current path usable for one more release. **They
are not the strategy.** The strategy is finish #442 (c), make
`lib/hamui.ad` the base for everything visible, and let the
compositor become the thin blitter the rio spec said it would be all
along.

The Vulkan spine is the right LONG-TERM presenter — it is NOT a
near-term pivot, and the project memory (`project_gpu_track`) already
scopes it correctly as Phase 2 hardware accel.

Recommendation: **pivot, staged as Stage A → B → C → D above.** Do
not stay the course past P0-B.

---

## Cite map

- Compositor monolith: `user/hamUId.ad` (27 289 LOC)
- Per-pixel cascade: `user/hamUId.ad:10536-11803` (`daemon_pixel`,
  ~1267 lines)
- SCENE_CACHE: `user/hamUId.ad:8801, 11985, 12064`
- WCACHE 400×300 cap: `user/hamUId.ad:8788-8791, 10445`
- Compositor never calls `lib/hamui.ad`: see
  `docs/de_perf_diagnosis.md` §5 lines 230-269
- #442 (c) blit protocol spec: `sys/src/9/port/devwsys.ad:61-98`
- Per-process `#w` bind, blocking reads landed: commit `616c41c4`
- P0-A cursor decouple landed: commit `0f4b2e19`
- P0-C drag-key gate landed: commit `a465991f`
- Diagnosis report: commit `31ae2b0b`, `docs/de_perf_diagnosis.md`
- Toolkit: `lib/hamui.ad` (3 713 LOC)
- Toolkit input pipeline (per-window pointer/keys files):
  `lib/hamui.ad:46-63`
- Kernel window server: `sys/src/9/port/devwsys.ad` (3 080 LOC)
- Per-window damage/serial: `sys/src/9/port/devwsys.ad:152-193`
- Native Vulkan spine: `lib/vk/*.ad` (1 800 LOC), commit `18361e7`
- GPU track scope: memory `project_gpu_track` (Phase 0 LANDED;
  Phases 1-4 ungated by user)
- DE-perf pivot directive: memory `project_de_perf_pivot`
  (2026-06-13)
- GUI toolkit + DE rewrite track: memory
  `project_gui_toolkit_de_rewrite`
- MATE-mirror rewrite directive: memory
  `project_de_mate_mirror_rewrite`
- DE terminal namespace gap: memory `project_de_terminal_namespace`
