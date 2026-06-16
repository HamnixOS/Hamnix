# Hamnix DE — scene-file display architecture

**Status:** design spec (2026-06-15). Supersedes the legacy hamUI /
pixel-compositor stack, which is being gutted and rebuilt against this
document. This is the contract to build the new DE against.

## 1. Why this exists

The legacy DE pushed *pixels*: each window owned a per-window RGBA
backbuffer in the kernel, the client committed pixel bytes, and a
29k-line compositor blitted them. Every recurring failure lived in that
pixel path:

- **OOM** — 32 per-window 4 MiB framebuffers = 253 MB of static BSS.
- **Privilege gates** — a window spawned from a non-hostowner namespace
  couldn't write its own backbuffer, so apps/menus/terminals never
  painted.
- **FPS collapse** — one serial loop did input→composite→scanout, so any
  heavy composite starved the cursor to ~0.2 Hz.
- **Un-debuggable** — the only window into the system was a periodic PNG.
  A PNG of a crashed box looks like a PNG of a slow frame, so
  "opening a window OOMs the machine" was invisible until a human booted
  it.

The root cause is that *the engine renders to opaque pixels the developer
cannot read*. This architecture inverts that: **a window publishes a
display list as a human-readable file; the compositor reads those files,
stacks them by z, and one rasterizer turns the result into pixels.** The
kernel owns no per-window pixel buffers. The frame is a value you can
`cat`, `grep`, `diff`, record, and replay.

This is Plan-9-shape (everything is a file) and it dissolves the bug
classes above by construction rather than patching them.

## 2. The model in one paragraph

Each window is a directory in the wsys file server. The window's
**content** is a `scene` file: a line-oriented text display list in
window-local coordinates. A client (via `lib/hamui.ad`) rewrites its
whole `scene` whenever its content changes and pokes `ctl` to publish the
frame. The compositor wakes (event-driven), diffs the new scene against
the previous one to compute a damage rectangle, re-rasterizes only that
rectangle into a per-window pixel **cache**, and blits the caches z-ordered
to `/dev/fb`. The cursor and window chrome are the compositor's own
scenes, composited without ever waking the client.

## 3. Namespace layout

```
/dev/wsys/
    ctl                  # server-wide: newwindow, stats (read), teardown
    fb                   # final framebuffer sink (rasterizer writes here)
    cursor/scene         # the cursor's own tiny always-on-top display list
    by-name/<name>  ->   <wid>     # name->wid links, for gates/tools
    <wid>/
        scene            # client WRITES display list; compositor READS
        ctl              # window control (geometry, z, decorate, commit, damage)
        event            # client READS focus-routed input (window-local coords)
        winid            # read-only: this window's id
```

A window is created by writing `newwindow` to `/dev/wsys/ctl`; the server
returns a `wid` and binds the `<wid>/` directory into the caller's
namespace. The client never needs hostowner — it owns the files under its
own `<wid>/` (owner = the creating PID or an ancestor; same ownership
rule the kernel already enforces post-#455/#456).

## 4. Scene file grammar

One primitive per line. Whitespace-separated tokens. `#RRGGBB` or
`#RRGGBBAA` colors. Coordinates are **window-local** (top-left = 0,0);
the compositor translates by the window origin, so a window can move with
**no client redraw**. Lines beginning with `#` (followed by space) and
blank lines are comments.

```
# scene v1 win=<wid>
clip   x y w h                      # set clip rect (window-local); default = whole window
fill   x y w h #RRGGBB[AA]          # solid rectangle
rect   x y w h #RRGGBB[AA]          # alias of fill (semantic: a filled box)
stroke x y w h thick #RRGGBB[AA]    # rectangle outline
line   x1 y1 x2 y2 thick #RRGGBB[AA]
text   x y "string" #RRGGBB[AA]     # baseline-anchored, default DE font
glyphs x y "string" #RRGGBB[AA]     # monospace cell text (terminals)
image  x y w h tile=<id>            # blit a bitmap from this window's tiles blob
damage x y w h                      # OPTIONAL explicit damage hint (else compositor diffs)
```

**Primitive tiers** (the rasterizer's vocabulary is the only thing that
changes between a TUI floor and a full graphical DE — the file protocol,
compositor, input model, and gates are identical at every tier):

| Tier | Primitives | Unlocks | Needs tiles blob |
|------|-----------|---------|------------------|
| Floor | `fill`, `text`, `clip`, 24-bit color | colored terminals, menus, text apps | no |
| Widget | + `rect`, `stroke`, `line`, `glyphs` | calculator, 2048, file manager, all 2D widgets | no |
| Bitmap | + `image`/`tile` | photos, video, sprites, browser content | yes |

We build the Floor+Widget tiers first (they cover the entire classic
desktop and games like 2048 with real colored tiles). Bitmap is additive
later, per-app, with no protocol change.

Example — a 2048 board, readable as text (you can see the game state):

```
# scene v1 win=5
fill  0  0 340 340 #bbada0
rect 10 10  75  75 #eee4da
text 40 38 "2"     #776e65
rect 95 10  75  75 #ede0c8
text 125 38 "4"    #776e65
rect 180 10 75  75 #f2b179
text 205 38 "8"    #f9f6f2
```

## 5. Bitmaps — the tiles blob

When a window uses `image`, the pixels live in a sibling
`/dev/wsys/<wid>/tiles` blob, referenced by `tile=<id>`. The display list
stays readable text; only opaque bitmap data goes in the blob. Tiles are
double-buffered (write new tile, then reference it) so a video frame swap
never tears. A window with no `image` primitives never allocates a tiles
blob.

## 6. Update model — rewrite-on-change, not edit-in-place

**The client rewrites the whole `scene` file when its content changes,
then pokes `commit`.** It does *not* edit the file in place, and it does
*not* rewrite on a clock.

- **Whole-file rewrite, not in-place edit.** A scene is kilobytes of text;
  regenerating it is free next to rasterizing. In-place editing fights the
  byte-stream medium (a changed line that grows shifts every following
  byte). Rewrite and stop worrying.
- **On change, not per frame.** The toolkit holds the retained widget tree
  and writes only when the model changes. A static calculator writes its
  scene once at startup, then again only on a keypress. An idle desktop
  writes nothing and costs nothing. Per-frame rewrites happen only during
  an actual animation, where the list is tiny and bounded.
- **Virtualize.** A scene emits only primitives inside the window's `clip`
  (the visible screenful). A 10k-line editor's scene is ~50 `text` lines,
  not 10,000. The display list is always O(on-screen), never O(content).

### Frame atomicity (no torn reads)

The client writes the full new list to `scene`, then writes `commit` to
`<wid>/ctl`. The compositor reads `scene` **only** on the commit signal,
so it never observes a half-written frame. This mirrors the existing
data+commit-byte pattern. `commit` bumps a per-window generation counter;
the compositor compares generations to know which windows changed.

## 7. Compositor pipeline

Event-driven; no polling. Per published frame:

1. **Wake** on a `commit` (or cursor move, or a WM op). No work when idle.
2. **Read** the `scene` files whose generation changed.
3. **Damage** = diff the new display list against the previous one and
   take the bounding box of changed primitives. (The client may supply an
   explicit `damage` line to skip the diff on a hot path.) Diffing two
   small text lists is cheap and inspectable.
4. **Rasterize** the damage rect of each changed window's display list into
   that window's **pixel cache** (see §8). This is the only O(pixels) step
   tied to content, and it runs only when content changed.
5. **Composite** = blit the per-window pixel caches, z-ordered, clipped to
   the screen damage region, into `/dev/fb`. A window *move* re-blits the
   cache at a new position with **no re-rasterize** (content unchanged).
6. **Chrome** for decorated windows is drawn by the compositor around the
   cache (see §10).
7. **Cursor** is composited last from `cursor/scene`, independently (see §9).

## 8. Per-window pixel cache — evictable, regenerable

The `scene` file is the **durable source of truth**; the per-window
rasterized pixel buffer is a **cache**. Consequences:

- Rasterize (list→pixels) runs on content change; compositing just blits
  the cache. A move/raise/lower is a pure blit.
- The cache is **lazily allocated** on first draw and **evictable** under
  memory pressure — drop the pixels, keep the kilobyte of text, and
  re-rasterize on demand. (Client-pushed pixels could never do this; you'd
  have to wake the client to redraw.) This reuses the lazy-alloc machinery
  landed in the OOM fix (`devwsys` per-window framebuffer pointers) and the
  damage-clip cache from #409.
- Idle, never-drawn slots cost a pointer, not a framebuffer.

## 9. Cursor

The cursor is its own tiny scene (`/dev/wsys/cursor/scene`), always on
top, composited after everything else and **decoupled from window
recomposition**. A cursor move blits only the cursor's old and new rects
(restore-behind + draw), never the scene. This is what structurally
prevents the FPS collapse: cursor latency is independent of composite
load. Hardware-cursor offload is an optional later optimization behind the
same scene.

## 10. Window chrome — server-side decorations (SSD)

The **compositor owns the window frame.** A window sets one flag in its
`ctl`:

```
decorate 1     # app: compositor draws titlebar + min/max/close + border
decorate 0     # panel/menu/cursor/overlay: no frame, content only
```

The client draws *only content* into a content-sized scene and never
draws its own titlebar. The compositor draws the frame around the cache.

Why SSD, not client-drawn chrome (CSD):

- **Move/resize/close are 100% compositor-side, zero client round-trips** —
  instant even if the app is hung. CSD makes a hung app's window
  unmovable and unclosable.
- **Input routing stays trivial.** The compositor owns the frame region,
  so it *knows* a click on the titlebar is a WM action and a click in the
  content is for the app — and forwards only the latter (already in
  content-local coords). With CSD the compositor would have to ask the
  client "which part of you is a titlebar?" to route correctly.
- **One place for theming**, consistent across all apps. Matches the MATE
  model the DE mirrors.

`lib/hamui.ad` still draws *content* widgets (buttons, menubars, the 2048
board); it does **not** draw the window frame. Setting `decorate` and
getting a frame for free is the entirety of an app's chrome involvement.

## 11. Input & focus model

Input flows back through each window's `event` file. The compositor
hit-tests and translates coordinates into the target window's local space
(top-left = 0,0): the app only ever sees "event at (x,y) in my space" and
is ignorant of where it lives on screen.

Routing splits pointer from keyboard:

- **Pointer** (motion, button, scroll) → the window under the cursor.
  A press also raises + focuses that window. Events landing on the
  compositor-owned chrome are consumed as WM actions (move/resize/close)
  and **not** forwarded to the app.
- **Keyboard** → the **focused** window, which is not necessarily the
  hovered one (otherwise keys follow the mouse off the window mid-type).

Event line format (window-local):

```
m <x> <y> <buttons> <dz>          # pointer: position, button mask, scroll delta
k <down|up> <keysym> <mods>       # keyboard
f <in|out>                        # focus gained/lost
r <w> <h>                         # window resized by WM (new content size)
```

Focus policy is click-to-focus by default (configurable to follow-mouse).
Pinning pointer-vs-keyboard routing here is the fix for the legacy
"input leaks to the serial shell" bug, which came from a shared
`/dev/cons` + topmost-only focus.

## 12. lib/hamui.ad — the toolkit

App authors never touch scene files. `lib/hamui.ad` is a retained-mode
widget toolkit that:

- holds the widget tree and re-lays-out on state change;
- regenerates the display list and writes `scene` + pokes `commit`;
- computes/declares damage and clips/virtualizes scrolling containers;
- reads `event` and dispatches to widget handlers in window-local coords;
- sets `decorate` and lets the compositor own the frame.

App code is just: mutate a widget, the toolkit handles the rest.

```
btn7.on_click = fn() { model.push("7"); display.set_text(model.text) }
```

## 13. Efficiency invariants (the gate for committing to this)

- **Idle = zero work.** No state change → no scene write → no compositor
  wake. A static desktop costs nothing.
- **Work ∝ change, not screen size.** Damage is the diff of two small text
  lists; the rasterizer touches only the damaged rect. A blinking terminal
  cursor damages one cell.
- **Move = blit, not rasterize.** Repositioning a window re-blits its cache;
  no list→pixel work.
- **The only O(pixels) work** in the loop is "rasterize a damage rect on
  content change" + "blit caches when compositing." Everything else is
  O(visible widgets) of text.
- **Memory scales with drawn (not declared) windows**, and caches are
  evictable down to their text source under pressure.

## 14. Debuggability (the payoff)

The compositor's input is text files, so the toolchain is `cat`, `ls`,
`grep`, `diff`:

- "Does app A render?" → `grep -c text /dev/wsys/<wid>/scene`.
- "Why is the window invisible?" → `cat /dev/wsys/<wid>/ctl` shows `z=-1`
  (behind wallpaper) — a bug invisible in a PNG, obvious in text.
- **`scenedump`** snapshots every window's `scene`+`ctl` into a directory.
  That directory *is* the bug report, readable without QEMU.
- **Golden replay:** feed a captured scene dir to the rasterizer offline →
  one PNG, assert once. Window logic is tested as *text*; pixels are tested
  in isolation. No more pixel-diff heuristics that false-pass on a corpse.

### Gates (replace the heuristic PNG gate)

```
assert exists /dev/wsys/by-name/hamterm/scene        # app launched + got a window
assert grep -q 'glyphs' /dev/wsys/<term-wid>/scene   # terminal drew text
fps = read(scene-gen) delta over 1s                  # exact, not a vibe
assert read /dev/wsys/ctl stats: composites/s, windows, evictions
```

A box that OOMs on window-open shows the `newwindow` ctl write failing
with a named errstr, or the scene stream simply stopping — a named,
timestamped failure instead of a frozen image.

## 15. What gets gutted vs reused

**Gutted (legacy pixel stack):**

- the client-pushed per-window RGBA backbuffer `data`/`B`/`D` commit path;
- the procedural `daemon_pixel` / `window_render_self` cascade;
- the version-2 hostowner draw-permission gate;
- the in-compositor app duplicates (`APP_CALC/SYSMON/FILEMGR/EDITOR`), the
  dual panel (`hamde.svc`), and the legacy `MENU_OPEN` menu (audit §A.3–A.5);
- the legacy hamUI docs (`hamUI.md`, `de_correction_plan.md`,
  `de_perf_diagnosis.md`, `graphical_stack_audit.md`).

**Reused:**

- the `/dev/wsys` file-server + per-process namespace binding;
- the lazy per-window framebuffer allocation (OOM fix) as the cache backing;
- the damage-clip compositor + per-window cache concept (#409);
- the event-driven WaitQueue wake primitive (`core.ad`);
- the canonical `/dev/mouse` input injection (for gates) and `event` files;
- `lib/hamui.ad` as the toolkit, refactored to emit display lists.

## 16. Build order

1. **Scene server** — `<wid>/scene` + `ctl` (geometry/z/decorate/commit) +
   `winid`; ownership = creator/ancestor; `newwindow` on `/dev/wsys/ctl`.
2. **Rasterizer (Floor+Widget tiers)** — `fill/rect/stroke/line/text/
   glyphs/clip` → per-window cache. Stateless per primitive; golden-file
   tested in isolation.
3. **Compositor loop** — wake→read→diff-damage→rasterize→z-blit→fb, plus
   the evictable cache.
4. **Cursor scene** — independent always-on-top blit.
5. **Input + focus** — `event` files, window-local coords, pointer/keyboard
   split, chrome-event interception.
6. **SSD chrome** — compositor-drawn frame for `decorate=1`; move/resize/
   close WM ops.
7. **hamui.ad refactor** — retained tree → display-list emit + commit +
   event dispatch; virtualization.
8. **Apps on the new toolkit** — terminal, panel, menu, calculator, 2048,
   file manager — each a separate process drawing content only.
9. **Gates** — text-asserting scene gate + exact FPS + `scenedump` +
   golden replay; retire the heuristic PNG gate.
10. **Bitmap tier** — `image`/`tiles` blob, when a bitmap app needs it.

## 17. Open questions

- **Resize semantics:** does the WM resize re-rasterize content at the new
  size synchronously, or show the cache stretched until the client recommits
  at the new `r <w> <h>`? (Lean: stretch-then-recommit, for responsiveness.)
- **Sub-window/child surfaces** (popup menus, tooltips, combo dropdowns):
  separate short-lived windows with `decorate 0`, or in-scene primitives
  owned by the parent? (Lean: separate `decorate 0` windows, so the
  compositor z-orders and dismisses them uniformly.)
- **Font story:** one DE font atlas in the rasterizer (text/glyphs), or a
  per-window font selection in the scene grammar? (Lean: a small set of
  named atlases referenced by the `text` primitive.)
- **tiles blob transport:** shared-memory mapping vs file write — pick for
  the video/throughput case when the bitmap tier lands.
