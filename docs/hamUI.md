# hamUI — Hamnix's file-based window system

**Status:** design spec. **Renamed from `rio` 2026-05-27** (Plan 9
name collision). The bulk of this doc inherits its shape from Plan 9
rio (the design lineage); citations to Plan 9's `rio(1)` / `rio(4)`
etc. remain unchanged because they reference the canonical upstream.
Our system is `hamUI`.

Tagline: **"every window is a debug scope onto a namespace."** The
killer feature is AI-debuggability — every window's text content,
namespace state, and live I/O are file-readable from outside, so an
AI agent debugging Hamnix has the same access surface as a human SRE
(more thorough, actually, because state is exposed directly rather
than through pixels).

> **Hamnix-specific design overlays** (additions to the Plan 9 rio
> spec below). See [`TODO.md`](../TODO.md) § "`hamUI` window system"
> for the consolidated summary and phasing.

## H-§A. AI-debuggable file tree per window

In addition to the Plan 9 rio file tree documented in §2 below,
hamUI exposes on every window (`/dev/wsys/<wid>/`):

| File | Purpose |
|------|---------|
| `text` | UTF-8 scrollback (no screenshot OCR needed; AI reads directly) |
| `output` | Live tail of current command's stdout/stderr |
| `kbdin` | Write-only keystroke injection (rio already has this) |
| `cmd` | Write a command line, runs in window's shell (one-shot) |
| `ns` | Plain-text mtab dump (binds + mounts) |
| `pid` | Root pid of window's shell |
| `proc/` | Symlinked tree of `/proc/<pid>/*` for window's processes |
| `kind` | `text` / `x11` / `framebuffer` |
| `uid` | Current effective uid (changes after `newshell`) |
| `geometry` | minx miny maxx maxy |
| `framebuffer` | Mmap pixel buffer (kind=x11 / framebuffer only) |

Workflow example:
```
$ cat /dev/wsys                       # list all windows
$ cat /dev/wsys/3/text | tail -20     # see window 3's recent output
$ cat /dev/wsys/3/ns                  # see window 3's namespace
$ echo 'ls /etc' > /dev/wsys/3/cmd    # tell window 3 to run a command
$ cat /dev/wsys/3/output              # read the result
```

Plan 9 rio's draw protocol exposes pixels; hamUI's `text`/`output`/
`cmd`/`proc/` overlay exposes structured state. Both layers coexist —
pixel apps still work via the draw protocol; debug-tools and AI
agents prefer the text layer.

## H-§B. Per-window admin elevation

Default: every new window opens in the calling user's namespace
(regular user → restricted per `/etc/users/<name>.ns`; hostowner →
full). Two elevation idioms:

- **Within an existing window**: `newshell hostowner` (the security-
  model builtin landed `43d7499`) swaps the SHELL inside the window
  to a hostowner shell with the hostowner namespace. The window
  stays; contents elevate.
- **Direct admin window**: `hamUI new -as hostowner` prompts for the
  hostowner password upfront, spawns a fresh window already in
  hostowner namespace.

The window's `wctl` and the new `uid` file (see H-§A) record current
effective uid + namespace label, so `cat /dev/wsys` shows which
windows are elevated.

## H-§C. X11 / Linux apps via Xvfb-in-linux-ns

Firefox / Chromium / anything-X11 runs inside a kind=x11 hamUI window
backed by Xvfb (the X virtual framebuffer; ~2 MB binary in Debian, no
DRM, no Mesa).

```
hamUI new -kind x11 -cmd '/usr/bin/firefox'
```

The window child:
1. `rfork`s into a fresh per-window namespace
2. `enter linux { Xvfb :0 -screen 0 1024x768x24 -fbdir /tmp/hamui-fb-<wid>; firefox }`
3. Xvfb draws into `/tmp/hamui-fb-<wid>/Xvfb_screen0` (memory-mapped)
4. hamUI mmap's the same file from outside; on a refresh tick, blits
   the pixels into the window's region of the physical framebuffer

Mouse/keyboard translation: hamUI translates Plan-9-shape `/dev/mouse`
records into X11 protocol events written to Xvfb's listening unix
socket at `/tmp/.X11-unix/X0` inside the linux ns. ~300 lines of glue
per direction.

Plan-9-shape rationale:
- The X11 server is just another process in a namespace.
- The pixel buffer is a file.
- The X11 wire protocol is bytes on a unix socket — Plan-9-shape.
- All gnarly X11 logic is Xvfb's problem; hamUI just routes pixels +
  events.

Path to a real browser on Hamnix without writing our own X11 server
(multi-year project).

## H-§D. Drag-to-create-window (the gesture)

Plan 9 rio's canonical gesture, kept: **left-click on the root, drag
a rectangle, release**. On release, that rectangle becomes a new
window — by default a hamsh prompt. When a GUI command runs inside
(e.g. `firefox`), the window's `kind` field flips and it becomes
that app's window.

No right-click menus, no taskbar, no "new window" toolbar. The drag
IS window creation. User direction 2026-05-27:

> "left click and drag out a rectangle, that rectangle is the shell,
> once you run a GUI command inside it, just like in plan 9, the
> windows becomes that app. So instead of right click and open
> window, it's just left click hold, drag out a window."

Implementation: hamUI watches `#m` (mouse) events; a button-down on
the root + drag + button-up paints a rubber-band rectangle and, on
release, atomically: allocates a wid, `srv_post`s the per-window
file server, rforks the child, binds the per-window `/dev` into the
child's namespace, exec's hamsh. Same path as `/dev/wsys` write
`new -dx W -dy H`; the drag just synthesises the geometry.

## H-§E. Phasing — AI-debug FIRST

Reorders the rio-era phase list (§8 below) so the AI-debug unlocks
come BEFORE the graphical work:

1. **hamUI skeleton** — one window, ALL the AI-debug files (`text` /
   `output` / `kbdin` / `cmd` / `ns` / `pid`) working in text mode.
   **No framebuffer yet.** Unlocks AI collaboration well before
   graphical OS. **LANDED 2026-05-28**: see
   `sys/src/9/port/devwsys.ad` for the cdev backend,
   `tests/test_hamUI_phase1.ad` for the regression. Implements
   `text` (64 KiB ring tee'd from devcons_write), `output` (16 KiB
   ring reset on cmd injection), `cmd` (4 KiB queue, drained by
   devcons_read + FD_STDIN_MARK arms in lieu of `kbdin`), `ns`
   (plain-text mtab), `pid`, `uid`, `kind`, `geometry`, and the
   `/dev/wsys` listing. `kbdin` deferred to Phase 2 — Phase 1's
   `cmd` queue already supplies the same AI-debug capability.
2. Multi-window via `/dev/wsys` (proves per-window-namespace
   invariant).
3. Per-window namespace + elevation visible in `uid` / `ns` files.
4. Framebuffer-backed pixel windows + drag-to-create gesture.
5. X11 bridge (Xvfb + event translation).
6. Snarf, wctl resize/move, focus policies.

Phase 1 alone is strategically significant: Hamnix becomes the OS an
AI can fully debug while you're still on a serial console.

## H-§F. Retired open questions (from §9 below)

- **Q1: daemon-mode (not PID 1).** Less invasive; matches Plan 9.
- **Q2: multiplexed keyboard.** Symmetric with mouse; more code but
  better composition with the `kbdin` AI-debug feature.
- **Q3: defer acme.** Hamsh + ported Unix programs first.
- **Q4: strict Plan 9 draw protocol.** **SUPERSEDED** by H-§G — we go
  text-readable hamML + framebuffer hybrid instead of the binary
  /dev/draw op stream. See H-§G for rationale.

## H-§G. Native draw protocol — layered markup + framebuffer hybrid

The Plan 9 draw protocol is opaque binary ops on `/dev/draw`. The
framebuffer (Phase 4 in earlier revisions of H-§E) was opaque pixels.
Both choices fight the AI-debug story. H-§G replaces them with a
**layered, text-readable draw model** so an AI agent can `cat
/dev/wsys/<wid>/draw/chrome/markup` and read what's drawn the same
way it reads `text` and `cmd`.

### File layout

```
/dev/wsys/<wid>/draw/
├── ctl                 # mklayer / rmlayer / clear / setz / ls
├── chrome/             # named layer; layer name is the directory
│   ├── kind            # "markup" or "fb"
│   ├── z               # explicit integer z-height (higher = on top)
│   ├── opacity         # 0..255 layer-wide alpha (multiplies per-pixel)
│   ├── geometry        # "x y w h" — layer can be smaller than window
│   ├── markup          # hamML text  (if kind=markup)
│   └── fb              # mmap pixel buffer RGBA8888 (if kind=fb)
├── content/
│   └── ...
├── cursor/
│   └── ...
└── (any other named layer the app wants)
```

Layers are addressed by name, not number. `chrome`, `content`,
`tooltip`, `floppy-dialog` — whatever the app chooses. Z-height lives
in each layer's `z` file as an explicit integer; the compositor walks
layers ordered by z ascending. Two layers at the same z are an
undefined order (don't); use ctl `setz <layer> <n>` to nudge.

`/dev/wsys/<wid>/draw/ctl` accepts:
```
mklayer <name> markup [w h]      # create markup layer; geometry defaults to window
mklayer <name> fb w h [bpp]      # create framebuffer layer; w/h required
rmlayer <name>                   # remove
clear <name>                     # zero the layer's content
setz <name> <n>                  # set z-height
ls                               # write the listing back; readers see active layers
```

`/dev/wsys/<wid>/draw` (read, no slash) returns ordered listing:
```
chrome     z=100  kind=markup  10x10..630x40    opacity=255
content    z=200  kind=fb      0x40..640x440    opacity=255
cursor     z=900  kind=markup  120x80..136x96   opacity=255
```

### Arbitrary layer count

No hard cap. Rule of thumb: **fewer well-defined layers > a horde of
tiny layers.** A file manager wants ~4 (chrome, file-list, selection,
drag-preview), not 50. The compositor cost is per-pixel-covered, not
per-layer, but cache pressure grows with layer count.

### hamML (markup grammar — minimal v1)

```xml
<window title="Files" w="640" h="480">
  <rect x="0" y="0" w="640" h="40" fill="#222"/>
  <text x="48" y="28" fill="#fff" font="sans" size="14">Documents</text>
  <image x="8" y="8" w="32" h="32" src="/usr/share/icons/folder.png"/>
  <image x="0" y="120" w="640" h="360" src="fb:content"/>
  <button x="540" y="450" w="80" h="20" id="close">Close</button>
  <group transform="translate(20,200)">
    <line x1="0" y1="0" x2="100" y2="0" stroke="#888" width="1"/>
    <text x="0" y="-4" fill="#fff" size="10">section</text>
  </group>
</window>
```

Tags v1:
- `<rect>` `<line>` `<text>` `<image>` `<group transform=...>` — shapes
- `<button id=...>` `<input id=... placeholder=...>` — widgets (emit
  events to `/events`)
- `<window ...>` — top-of-layer metadata only on markup layers

Attributes: `x`, `y`, `w`, `h`, `fill` (CSS-shape `#rrggbb` or
`rgba(r,g,b,a)`), `stroke`, `width`, `opacity` (0..1 per-element),
`font` (`mono`/`sans`/`serif` v1), `size` (px), `anchor`
(`start`/`middle`/`end` for text alignment), `transform` (translate
only v1; rotate/scale later).

**No flow layout.** Every element has explicit position. Matches
acme aesthetic + makes AI reasoning trivial.

`<image src="fb:<layername>">` composites another layer's framebuffer
inside a markup layer — that's how an X11 fb layer gets a markup
chrome wrapped around it (see "X11 as a layer" below).

### Framebuffer layers (kind=fb)

`/dev/wsys/<wid>/draw/<layer>/fb` is a mmap'd RGBA8888 buffer
(W×H×4 bytes). Apps that want raw pixel access write here. Xvfb
points its screen 0 framebuffer at this file (Phase 5). A direct-
pixel native app does the same.

### Per-pixel alpha + per-layer opacity

Both. Each pixel in an fb layer carries its own A channel (RGBA8888,
premultiplied). Each layer also has a single `opacity` 0..255 that
the compositor multiplies in. So a tooltip can be a markup layer at
opacity=200 with text that itself has rgba(255,255,255,255) — the
layer-wide opacity wins.

Markup layers rasterise to RGBA internally; the compositor treats
them identically to fb layers post-rasterise.

### Dirty rectangles (efficient repaint, zero AI overhead)

**Apps write whole-layer markup or whole-layer pixels.** Simple write
semantics; no app-side dirty tracking.

**The compositor diffs.** A userland renderer daemon (see below)
keeps the previous rastered RGBA bitmap of every layer in memory.
On a layer-file write, it rasterises the new content, runs a coarse
diff against the cached previous rastered bitmap (16×16 tile
comparison), and re-composites only dirty tiles.

Cost: one RGBA bitmap per layer in renderer RAM (~4 bytes per pixel
covered). Bounded by total covered area, not layer count. v1 can
skip the diff entirely and full-composite on any change — adequate
for 60 FPS at 800×600 on this hardware; add the diff path later if
it bottlenecks.

### Event stream

`/dev/wsys/<wid>/events` — text-shape, one event per line:

```
click x=545 y=455 layer=chrome id=close
key A meta=ctrl
key BACKSPACE
resize w=800 h=600
focus
blur
mousemove x=120 y=80
scroll dy=-3
```

`layer=` tells the app which layer the pointer hit (so an X11 fb
layer gets X11-shape coords; a chrome markup layer gets widget-id
semantics). `id=` is the markup element's `id` attribute. Hit-
testing happens in the compositor since it owns the rasterised
layer tree.

### X11 (Phase 5) as a layer

`hamUI new -kind x11 -cmd '/usr/bin/firefox'` becomes:

1. Create `chrome` layer (kind=markup, z=200) — title bar, close
   button, scrollbar gutter
2. Create `content` layer (kind=fb, z=100, 640×400) — Xvfb mmaps
   `draw/content/fb` as its screen 0 framebuffer
3. Xvfb runs inside the linux ns, draws into `content/fb`
4. `chrome/markup` references the X11 content with
   `<image src="fb:content"/>`
5. Compositor blits content layer with chrome layer on top
6. Mouse events with `layer=content` route to Xvfb (translate to X11
   events sent to Xvfb's unix socket); events with `layer=chrome`
   route to the chrome's widget IDs

No special X11 path in the compositor. X11 is just a fb layer with
an app that's listening to the X11 wire protocol on the side. Same
machinery serves any advanced native app that wants raw pixels.

### Renderer lives in userland (hamUId daemon)

`hamUId` is a userland daemon launched at boot, owns:
- The rastered-layer cache (one RGBA per active layer)
- The hamML parser + rasteriser (bitmap-font text, shape primitives)
- The compositor (final blit to the physical framebuffer)
- The hit-test machinery (translates mouse/touch coords to
  `layer=` + `id=` events back to `/events`)
- The font store (loads `/usr/share/fonts/<name>.bdf` on demand)

The **kernel** owns just the cdev plumbing — `/dev/wsys/<wid>/draw/*`
is a glorified tmpfs subtree with notification on write. Heavy
graphics logic stays out of ring 0.

Bonus: `hamUId` can be swapped (alternate renderer impls), restarted
on crash without dropping the kernel, even rewritten in a different
language someday.

### Fonts

v1 ships three bitmap fonts:
- `mono` — 8×16 VGA-style (terminal default)
- `sans` — 12pt clean sans-serif (UI default)
- `serif` — 12pt serif (reading)

Format: BDF or PCF (text-shape, AI-readable, parser is small). Lives
at `/usr/share/fonts/<name>-<size>.bdf`. Fallback: missing font →
`mono`. TTF rasterising is a later addition (`hamUId` can swap in a
TTF backend without protocol change).

### Phasing update (replaces H-§E item 4)

H-§E's Phase 4 ("framebuffer-backed pixel windows + drag-to-create
gesture") becomes:

4a. **Draw protocol primitives** — kernel cdev plumbing for
    `/dev/wsys/<wid>/draw/<layer>/*`; `ctl` verbs; tmpfs-shape
    storage. No rasterisation yet; just the file surface.
4b. **`hamUId` renderer daemon** — userland; parses hamML, rasters,
    composites to a single fb (could be VGA text-mode emulation for
    bring-up, then real fb).
4c. **Framebuffer driver** + drag-to-create gesture.
4d. **Bitmap-font store** + the three v1 fonts.

5. **X11 (Phase 5)** — Xvfb points at a kind=fb layer; mouse/kbd
   translation. As described above.
6. **Snarf, wctl resize/move, focus.**

The rest of this document is the design lineage from Plan 9 rio. The
sections above (H-§A through H-§F) are the Hamnix-specific overlay.
The naming convention `rio` in the text below refers to the
**upstream Plan 9 implementation** which we cite throughout; our
system is `hamUI`, sharing rio's load-bearing invariants but adding
the AI-debug + elevation + X11 + drag-create features above. Hamnix
is currently console-only (VGA text + EFI GOP text-mode framebuffer)
per the explicit end-game scope in [`STATUS.md`](../STATUS.md). No
implementation work is in flight yet.

---

`rio` is a userspace 9P file server. Each window is a namespace; the
user manipulates the system by reading and writing files inside that
namespace. There is no graphical C API. There is no client library to
link against. A program that wants to draw or read input opens files
under `/dev`, just like every other Plan 9 program. See Plan 9's rio
for the canonical reference (`/sys/src/cmd/rio/` on 9front), and `rio(1)`
/ `rio(4)` in the Plan 9 4th edition manual for the user-facing
contract this document mirrors.

---

## 1. Philosophy and Plan 9 alignment

A rio window is **not** a region of a framebuffer; it is a per-process
namespace. When you "open a window" you are forking a new namespace,
binding rio's per-window file server into `/dev`, and running a shell
or program inside that namespace. The program inside cannot tell that
other windows exist. Its `/dev/mouse` returns only events directed at
it; its `/dev/cons` returns only the keystrokes typed while it has
focus; its `/dev/draw/<id>/data` writes only ever affect its own
rectangle of the screen.

This is the literal Plan 9 model. The user said it best:

> "If you cat the mouse file in two different windows, when you move
> the mouse in one you see it there, and then in the other, you see it
> in the other, but never both."

The constraint above is the load-bearing invariant. Every design
choice in this spec exists to preserve it.

Hamnix already has the 9P plumbing this depends on: per-process
`Pgrp` namespaces (`docs/distro-namespaces.md`), `rfork(RFNAMEG)` to
fork a fresh namespace, `bind(2)` / `mount(2)` to graft file servers,
the kernel-internal `#X` device aliases (`#m` mouse, `#c` cons, `#s`
srv, …), and the 9P V0..V3.5 base that lets a userspace process serve
a file tree to other userspace processes through `srv(3)`. rio is the
first user of all of those at once.

---

## 2. The rio file tree

After rio binds its per-window server into a window's namespace, the
window's `/dev` looks like this:

```
/dev/
    cons              text console; reads = kbd, writes = display
    consctl           text control (raw mode, echo on/off, …)
    mouse             49-byte ASCII mouse events
    cursor            write to set cursor shape; read = current shape
    draw/
        new           write returns "id [0-9]+\n"; read lists ids
        <id>/
            data      binary draw protocol bytes
            ctl       text: resize, set-clip, set-screen-image, …
            refresh   read blocks until refresh needed; one-shot
            colormap  text RGBA colormap for indexed images
    wctl              text per-window control; read = geometry
    wsys              text system-wide; write "new …" spawns window
    winname           read = window name; write = rename
    snarf             read/write system clipboard
    text              the window's text-mode console; hamsh sits here
    label             read/write the window's title-bar label
    kbdin             write-only; inject synthetic keystrokes
    screen            read = screen dimensions, depth, refresh rate
```

Files under `/dev/draw/<id>/` only exist while the id is open;
closing the last reference on `/dev/draw/<id>/data` evicts the id
and its sibling files vanish.

`/dev/wsys` is the **only** entry in this tree that is shared
between windows. Every other file is window-private. The naming
convention is exactly Plan 9's so that ported Plan 9 programs work
without source changes.

### 2.1 `/dev/mouse`

Each read returns one fixed-width ASCII record:

```
m %11d %11d %11d %11d\n
  ^x    ^y    ^buttons ^msec-since-boot
```

That is 49 bytes: 1 (`m`) + 1 (space) + 11 (`x`) + 1 + 11 (`y`) + 1
+ 11 (`buttons`) + 1 + 11 (`msec`) + 1 (`\n`). Records are emitted
in arrival order; the reader sees the same record exactly once.

| Field   | Width | Meaning                                              |
|---------|-------|------------------------------------------------------|
| x       | 11    | pixel x, window-relative; clamped to `[0, w-1]`      |
| y       | 11    | pixel y, window-relative; clamped to `[0, h-1]`      |
| buttons | 11    | bitmask: 1=button1, 2=button2, 4=button3, 8=scrollup, 16=scrolldown |
| msec    | 11    | milliseconds since kernel boot (monotonic; from `/dev/time` epoch) |

The window-private read invariant: a `mouse` opened in window A
returns only events whose `(x, y)` fell inside A's rectangle at the
moment rio sampled the hardware. Events delivered to A are NEVER
observable to B and vice-versa.

A write to `/dev/mouse` repositions the cursor. The write format is
the same record shape; `buttons` and `msec` are ignored. Writing only
works if the window has focus, otherwise it returns `Eperm` (`Permission denied`).

Reads block until an event is available. Non-blocking reads (the fd
opened with `OREAD|ONONBLOCK` — when Hamnix lands that flag) return
zero bytes and set `errstr` to `would block`.

### 2.2 `/dev/cons` and `/dev/consctl`

`/dev/cons` is the per-window text console. It is the same shape as
the existing kernel `/dev/cons` cdev (M16.94, `sys/src/9/port/devcons.ad`)
but window-private:

  - **read**: returns user keyboard input. UTF-8. Blocks until at
    least one rune is available (cooked mode) or one byte is
    available (raw mode).
  - **write**: bytes appear in the window's text area. Interpreted
    by rio's terminal emulator (cursor motion, line wrap, scroll,
    selection refresh).

`/dev/consctl` is the text control channel. One command per write:

```
rawon           disable line buffering; reads return per-keystroke
rawoff          re-enable line buffering
holdon          freeze output; further writes to /dev/cons block
holdoff         release hold
```

`/dev/consctl` reads return one line per active mode, e.g.
`rawon\nholdon\n`.

`hamsh` runs against `/dev/cons` by default. The user pressing keys
in the window writes to the focused window's underlying kbd FIFO;
rio routes those bytes to that window's `/dev/cons` read side.

### 2.3 `/dev/draw/*` — Plan 9 draw protocol

This subtree is Plan 9's `draw(3)` interface, ported. The full
semantics of the binary draw protocol (the byte commands accepted
on `data`) are deferred to a follow-on spec; we list only the file
shapes here.

  - **`/dev/draw/new`**:
      - write of arbitrary bytes (the request body is currently
        unused; the act of writing allocates) returns a new
        decimal id on the **next read** of the same fd. Reference
        9front semantics: the response is the integer id as ASCII,
        newline-terminated.
      - read with no preceding write returns the list of open ids
        in this window, one decimal per line.
  - **`/dev/draw/<id>/data`**:
      - write: a sequence of draw-protocol commands (see §5).
      - read: returns ACKs for any commands that produced output
        (e.g. font metrics requests, image bit-extraction).
  - **`/dev/draw/<id>/ctl`**:
      - write: text command. Recognised commands:

        | Command                       | Effect                              |
        |-------------------------------|-------------------------------------|
        | `resize -dx <w> -dy <h>`      | reshape the drawing context         |
        | `set-clip <minx> <miny> <maxx> <maxy>` | set the clip rectangle    |
        | `set-screen-image <imgid>`    | retarget output                     |
        | `flush`                       | force a renderer flush              |
        | `font <name>`                 | set the current text font           |

      - read: text summary of the context's state (size, clip,
        screen, font). Field-per-line so it's `awk`-able.
  - **`/dev/draw/<id>/refresh`**:
      - read **blocks** until the context needs repaint (the user
        resized the window, uncovered it, switched virtual desk,
        etc.). On wake the read returns a short ASCII record:

        ```
        r %11d %11d %11d %11d\n
          ^minx ^miny ^maxx ^maxy
        ```

        identifying the dirty rectangle in window coords. After
        the read returns, the next `data` write is expected to
        repaint at least that rectangle. There is no queue —
        consecutive refresh events coalesce into one wake.
  - **`/dev/draw/<id>/colormap`**:
      - read/write the indexed colormap for paletted images on this
        context. Format: one `index r g b a\n` row per entry.

### 2.4 `/dev/wctl`

Text per-window control. **Window-private** — `wctl` in window A
controls A, in window B controls B. Recognised writes:

| Command                | Effect                                                   |
|------------------------|----------------------------------------------------------|
| `resize -dx N -dy M`   | resize this window to N×M pixels                          |
| `move X Y`             | move the window's top-left to screen coords (X, Y)        |
| `current`              | raise to top and grab focus                              |
| `delete`               | tear down this window (its hamsh receives SIGHUP)         |
| `hide`                 | minimise / iconify                                       |
| `unhide`               | restore from hidden                                      |
| `scroll`               | enable terminal-emulator scroll-on-output                |
| `noscroll`             | disable                                                  |

A read of `/dev/wctl` returns one line:

```
%11d %11d %11d %11d %-12s %s\n
^minx ^miny ^maxx ^maxy ^state ^label
```

where `state` is one of `visible`, `hidden`, `current`. Matches
9front's `wctl(7)` shape so ported tools (`rio -i`, `wctl(1)`)
work unmodified.

### 2.5 `/dev/wsys` — system-wide, the only multi-window file

`/dev/wsys` is **shared** across all windows (every window's
namespace binds the same `#W/wsys`). Writes spawn new windows:

```
new                                     # 80×25 default
new -dx 800 -dy 600                     # explicit size
new -dx 800 -dy 600 -x 100 -y 100       # explicit placement
new -hide                               # spawn hidden
new -scroll /bin/hamsh                  # exec hamsh inside
new -pid                                # print new window's pid
```

A `new` write returns the new window's id (decimal) on the same fd's
next read, then EOF. The user gets a fresh namespace, a fresh shell,
and a fresh `/dev` tree as described above.

Read of `/dev/wsys` returns the live window list, one row per
window, in z-order top-first:

```
%11d %-32s %11d %11d %11d %11d %s\n
^wid ^name  ^minx ^miny ^maxx ^maxy ^state
```

### 2.6 The remaining files

  - **`/dev/winname`** — read returns the window's name (defaults to
    `window.<id>`); write sets it. The name is what shows in `wsys`
    listings and `wctl` reads.
  - **`/dev/snarf`** — system clipboard, UTF-8 text. Read returns the
    current contents; write replaces them. Shared across all windows;
    this is the deliberate exception to "every dev file is private".
    See §6 for the future binary-mime-typed extension.
  - **`/dev/text`** — convenience alias for the window's text-mode
    console (the byte stream the terminal emulator consumes). `hamsh`
    can be configured to attach to `/dev/text` instead of `/dev/cons`;
    the difference is that `/dev/text` is the *post-emulator* stream
    (already cooked through escape-sequence handling) whereas
    `/dev/cons` is the raw stream.
  - **`/dev/cursor`** — write the cursor shape (32×32 1-bpp + mask),
    read the current shape. Plan 9 `cursor(6)` format.
  - **`/dev/kbdin`** — write-only; injects synthetic keystrokes into
    this window's `/dev/cons` reader. Used for scripted-input tests
    and for accessibility tools.
  - **`/dev/screen`** — read returns the physical-screen geometry
    and pixel format. Shared (read-only) across windows; writes
    return `Eperm`.

---

## 3. Per-window namespace construction

The lifecycle of a new window — the **only** way a window's
per-namespace dev tree comes into being — runs as follows:

```
+--- rio (long-lived daemon, owns the physical screen + #m + kbd) ---+
|                                                                    |
|  read /dev/wsys for "new -dx W -dy H -scroll /bin/hamsh"           |
|     |                                                              |
|     v                                                              |
|  allocate wid; allocate per-window buffers (mouse FIFO, cons      |
|  FIFO, draw-id table, refresh wait queue)                          |
|     |                                                              |
|     v                                                              |
|  sys_srv_post('window.<wid>', srvfd)                              |
|     |  => /srv/window.<wid> appears in the global #s namespace     |
|     v                                                              |
|  rfork(RFPROC | RFFDG | RFNAMEG | RFENVG) — fork child task,      |
|     child gets fresh Pgrp                                          |
|     |                                                              |
|     v                                                              |
|  (in child) bind('#s/window.<wid>', '/dev', MREPL)                |
|     => child's /dev/mouse, /dev/cons, /dev/draw, etc. now          |
|        resolve to rio's per-window file server                     |
|     |                                                              |
|     v                                                              |
|  (in child) exec /bin/hamsh                                        |
|     |                                                              |
|     v                                                              |
|  hamsh reads /dev/cons; user types; rio routes keystrokes to       |
|  this window's cons FIFO; hamsh echoes via writes to /dev/cons.    |
+--------------------------------------------------------------------+
```

Two structural notes:

  - **`MREPL` vs `MBEFORE`**. The window child does `bind(MREPL,
    '#s/window.<wid>', '/dev')` so that the rio-served `/dev`
    completely replaces whatever `/dev` the parent had. The
    alternative is `MBEFORE`, which would layer rio's `/dev` *over*
    the parent's; this is rejected because it lets unprivileged
    `/dev/random` reads "fall through" to the kernel cdev and
    confuses the window-isolation story. The window child sees
    only what rio chooses to expose.

  - **Distro namespaces still work**. A rio window's child can
    re-bind further (e.g. run `distrorun debian hamsh` inside);
    its `/dev/mouse` is still rio's, because the distro recipe
    binds `/etc /usr /lib /var` but explicitly preserves `/dev`.
    See `docs/distro-namespaces.md` §"preserve shared file servers".

---

## 4. Mouse multiplexing model

This section is the heart of the spec — the load-bearing invariant
("never both") lives or dies here.

```
              hardware mouse
                    |
                    v
            kernel #m (drivers/input/mouse.ad)
                    |
                    |  rio is the sole reader
                    v
+---------------- rio ----------------+
|  read #m -> (raw_x, raw_y, btns)    |
|  apply cursor accel/transform       |
|  global_x, global_y := …            |
|                                      |
|  let target_wid =                    |
|     window_at_point(global_x, global_y, focus_policy)  |
|                                      |
|  let (lx, ly) :=                     |
|     to_window_local(target_wid, global_x, global_y)    |
|                                      |
|  write_record(per_window_mouse_fifo[target_wid],       |
|     m, lx, ly, btns, msec)                              |
+--------------------------------------+
                    |
   per_window_mouse_fifo[A]   per_window_mouse_fifo[B]
                    |                    |
         read /dev/mouse        read /dev/mouse
            (in window A)         (in window B)
```

### 4.1 Single physical reader, fanout in rio

The kernel `#m` device has **exactly one** reader: rio. No other
process opens `#m` directly. (Privileged debug tools may bypass —
e.g. a recovery hamsh — but the normal path is rio-only.) This is
enforced by `#m` having exclusive-open semantics; the first opener
holds it and subsequent `open("#m/mouse")` returns `Einuse`.

Why one reader? Because if two processes both drained `#m` they'd
race for each event and neither would see the full stream. rio
*must* see every event to decide which window it routes to.

### 4.2 Hit-testing

For each event rio just dequeued from `#m`:

  1. Apply cursor acceleration / transform to get global pixel
     coords `(gx, gy)`.
  2. Walk the window list top-first; find the first window whose
     rectangle contains `(gx, gy)`. Call it `target_wid`.
  3. If no window contains the point (event landed on the root
     window / desktop), the event is dropped on the floor — there
     is no "root window mouse file" in V0.
  4. Translate to window-local coords: `lx = gx - window.minx`,
     `ly = gy - window.miny`.
  5. Emit one 49-byte record into the per-window mouse FIFO for
     `target_wid` only.

A reader on window B's `/dev/mouse` never sees an event whose
hit-test resolved to window A. The fanout is **at the source** in
rio — by the time the bytes reach a per-window FIFO they are
already committed to one window.

### 4.3 Focus policy

  - **V0: pointer-follows-focus.** The window under the cursor gets
    every event, click or no click. This is Plan 9's classic
    behaviour and the easiest to reason about — hit-test is the
    *only* rule. The keyboard follows the same window the pointer
    is over.

  - **V1: click-to-focus.** The mouse events still go to the window
    under the pointer (hover events are not focus-changing), but
    keyboard events route to whichever window most recently
    received a button-down event. This decouples the mouse and
    keyboard focus.

  - **V2: explicit focus via `wctl current`.** A program can grab
    focus by writing `current` to its `/dev/wctl`. Useful for
    full-screen apps and modal dialogs.

The policy is a runtime setting (`/dev/wsys` write `focus pointer`
or `focus click`); the default is `pointer`.

### 4.4 Cursor warp and constraint

`write` to `/dev/mouse` warps the cursor to the given coordinates.
The write is only honored when the writing window has focus
(otherwise `Eperm`). Cursor warping is window-local: writing
`(50, 50)` warps the cursor to the writing window's `(minx+50,
miny+50)`. A program cannot warp the cursor outside its own
window without first taking the screen via `/dev/wsys grab`
(deferred to V2).

### 4.5 Buffer sizing and overflow

Each per-window mouse FIFO holds at most **64 events** (64×49 =
3136 bytes — fits comfortably in one slab object). On overflow,
rio drops the **oldest** event and replaces it; mouse traces are
not loss-critical and the freshest position matters more than the
history. (Plan 9 drops the same way; cf. `/sys/src/cmd/rio/mouse.c`.)
A read that arrives while the FIFO is empty blocks; a write to
`#m` while the target window's FIFO is full triggers a `printk`
once per second to flag the dropped-event condition for debugging.

---

## 5. Drawing model

### 5.1 V0 — text only, no framebuffer

In V0 rio serves the file tree as described above with one
restriction: `/dev/draw/new` returns `Enodisplay` (`errstr: no
display`). The `/dev/draw/<id>/*` subtree is empty because no ids
exist. Programs that try to draw fail-soft; programs that only
use `/dev/cons` work fine.

V0 ships on the existing serial / VGA-text infrastructure. Rio's
"compositor" is a virtual-terminal multiplexer: it owns the
physical text framebuffer (`drivers/video/console/fb_text.ad`),
keeps a per-window scrollback buffer, and on each redraw paints
the focused window's text into a rectangle of the screen.

Window boundaries in V0 are drawn with text characters
(`─ │ ┌ ┐ └ ┘`); this is the same trick `screen(1)` and `tmux`
use, and matches the spirit of Plan 9 rio running on a serial
console (which historically just refused).

### 5.2 V1 — framebuffer-backed `/dev/draw`

V1 lights up `/dev/draw/new` against the EFI GOP framebuffer
(`drivers/video/console/fb_text.ad`'s pixel-mode sibling, when
that lands). The draw protocol accepted on `/dev/draw/<id>/data`
is a strict subset of Plan 9's `draw(3)`:

| Byte | Command            | Body                                          |
|------|--------------------|-----------------------------------------------|
| 'b'  | allocimage         | id[4] screenid[4] r[16] chan[4] repl[1] value[4] |
| 'd'  | draw               | dstid[4] srcid[4] maskid[4] r[16] p0[8] p1[8] |
| 'i'  | initdisplay        | (V1: no-op; rio inits at startup)             |
| 'l'  | line               | dstid[4] p0[8] p1[8] end0[4] end1[4] radius[4] srcid[4] sp[8] |
| 'p'  | poly               | dstid[4] n[2] end0[4] end1[4] radius[4] srcid[4] sp[8] pts[n*8] |
| 'r'  | read               | id[4] r[16]                                   |
| 's'  | string             | dstid[4] srcid[4] fontid[4] p[8] clipr[16] sp[8] ni[2] runes[ni*2] |
| 't'  | top                | nw[2] wid[nw*4]                               |
| 'v'  | visibilityrect     | (deferred)                                    |
| 'x'  | freeimage          | id[4]                                         |

The full table is deferred to the V1 spec; this skeleton lists
just the load-bearing primitives. The key shape is **fixed-width
binary records, big-endian** to match Plan 9. (Yes, big-endian
here even though 9P is little-endian on the wire; this is Plan 9's
historical wart and we adopt it for source-compat with ported
Plan 9 programs.)

### 5.3 Long-term — full draw(3)

V2+ extends the protocol to the full Plan 9 draw protocol
(`/sys/src/libdraw/init.c` is the canonical client; the byte
codes are in `/sys/include/draw.h`). Out of scope for this spec;
listed in the implementation phases (§8) only.

### 5.4 No DRM, no Mesa, no Vulkan

Hamnix has no plans to implement OpenGL/Vulkan. The draw protocol
is what apps get. If an app wants 3D it composes its own software
rasteriser and writes the resulting pixels via `draw` ops. This is
the Plan 9 model and the README's "console-only" promise.

---

## 6. Snarf, focus, screensaver, accessibility (future direction)

These are out of V0 scope; one paragraph each describes the
direction so the V0 file tree leaves room.

  - **Snarf** (clipboard). `/dev/snarf` ships in V0 as UTF-8 text
    only. V1 may add `/dev/snarf/<mime-type>` subdirectories for
    binary contents (image/png, application/x-something); reads of
    `/dev/snarf` continue to return the text rendition for
    back-compat. Selection-vs-clipboard distinction is left to a
    second file (`/dev/primary`) if and when that matters.

  - **Focus and Z-order**. V0 implements pointer-follows-focus
    only (§4.3). Z-order is single-screen, painter's-algorithm,
    top-of-list-is-front; `wctl current` raises a window. V2 may
    add multiple virtual screens (`/dev/wsys` write `screen new`).

  - **Screensaver**. Rio polls `/dev/mouse` and `/dev/cons` for
    activity; after `$BLANKTIME` seconds of idle (read from the
    `BLANKTIME` env var, default 600), it stops painting and goes
    dark. Any input wakes it. No password gate in V0 — that's a
    separate `/bin/lock` program (cf. Plan 9 `lock(1)`).

  - **Accessibility**. `/dev/kbdin` lets external tools inject
    keystrokes; equivalently, `/dev/wctl` writes can drive window
    layout. A screen-reader hooks `/dev/text` for every visible
    window and synthesises speech. None of this is rio's problem
    in V0; the file tree is the API and external programs supply
    the behaviour.

---

## 7. The retired VTNext design (historical)

Before rio, the window system was going to be **VTNext** — an
ESC-coded byte-stream wire protocol between apps, a `hamwd` display
daemon, and a renderer, with a single global `/dev/win/<wid>/draw`
file as the only window scoping. It was retired before any of it
shipped; this section records why, so the decision is not
relitigated.

VTNext was the **wrong shape** for the per-window-namespace model:

  1. **No per-namespace isolation.** A global `/dev/win/<wid>` tree
     let window A's process `open("/dev/win/B/events")` and snoop
     B's input. There was no namespace-private dev tree.

  2. **ESC framing assumed a terminal-emulator transport.** The
     `ESC ] … BEL` framing was meant for tunnelling through a tty;
     on a per-window file server it is pure overhead and prevents
     binary draw commands.

  3. **`hamwd` was a separate daemon from "the window system".**
     VTNext split drawing (`hamwd`) from compositing (renderer);
     rio collapses them into one 9P server.

  4. **The Plan 9 draw protocol already exists** and is a strict
     superset of what VTNext's drawing layer would have needed —
     no reason to invent a parallel encoding.

Recycling the ESC-coded framing as the internal byte-codec for
`/dev/draw/<id>/data` was also rejected: Plan 9's binary draw
protocol is well-specified, has reference implementations, and is
what ported Plan 9 programs (and a future `libdraw` shim) emit.

---

## 8. Implementation phases

No dates; the gates are landing order.

### Phase 1: `sys_srv_post` / `sys_srv_open` syscalls

The kernel `#s` device exists in spirit; the syscall surface that
lets a userspace process publish a srvfd into `/srv/<name>` is
what unblocks rio. A sibling agent is landing these in parallel.
Acceptance: `cat /srv` lists named servers; `cat /srv/foo` opens
a 9P channel into the publisher.

### Phase 2: rio skeleton — one window

`/bin/rio` accepts a srvfd (from its own `sys_srv_post`) and
serves a one-window file tree with `/dev/mouse`, `/dev/cons`,
`/dev/text`, `/dev/winname`, and stubs for the rest. No drawing.
`hamsh` runs inside; `cat /dev/mouse` works; the window is the
entire screen (no compositing yet). Acceptance: `cat /dev/mouse`
in the rio'd hamsh prints live mouse records; `cat /dev/mouse`
*outside* rio (in another login session, if such a thing existed
yet) returns `Einuse`.

### Phase 3: multi-window via `/dev/wsys`

Implement `wsys new`. Each new window gets its own namespace,
its own per-window FIFOs, its own srvfd. Demonstrate: open two
windows, `cat /dev/mouse` in each, move the mouse — events
appear in exactly one at a time. **This phase proves the
load-bearing invariant.**

### Phase 4: framebuffer-backed `/dev/draw`

Light up `/dev/draw/new` against the EFI GOP framebuffer. Land
the subset of draw ops in §5.2. Demonstrate: a "hello, world"
program that allocates an image, fills it, blits to the screen
image, refreshes on resize.

### Phase 5: snarf, wctl resize/move, focus follows mouse

The remaining file tree (`/dev/snarf`, `/dev/wctl` resize/move,
`/dev/cursor`). Polish phase. Demonstrate: select text in one
window with the mouse, paste into another via `cat > /dev/snarf`
/ `cat /dev/snarf`.

### Phase 6+: full draw protocol, virtual screens, lock screen, acme

Each gets its own follow-on spec.

---

## 9. Open questions

These are for the user to decide before Phase 2 starts.

**Q1: Should rio be PID-1 (replacing hamsh as init's exec target)
or run as a daemon spawned by hamsh?**

Trade-off: rio-as-PID-1 means every Hamnix session is windowed by
default and the "no window system" mode requires a kernel cmdline
flag (`hamnix.console=1`). rio-as-daemon means the serial console
hamsh is the default and the user types `rio` to enter windowed
mode; this matches Plan 9 (`rio` is launched from the cpu
terminal's profile script). Recommendation buried in §8 leans toward
daemon-mode (less invasive, no chicken-and-egg if rio fails to start),
but the user has final say.

**Q2: V0 keyboard model — does rio multiplex `/dev/cons` like mouse,
or is keyboard always-focused-window?**

Two answers:
  - **Multiplex** (analogous to mouse): every window has its own
    `/dev/cons` reader; rio decides which window receives a
    keystroke based on focus policy (§4.3). Symmetric with mouse;
    more code.
  - **Focused-window-only**: there is one keyboard, and it always
    goes to whichever window has focus. Windows without focus
    have `/dev/cons` reads that block forever. Simpler, but
    breaks the analogy with mouse and complicates background
    typing (paste, scripted input).

V0 leans toward the multiplexed model for symmetry; the user
should confirm.

**Q3: Do we want acme as a future userspace project (the
structured-editor 9P server that runs ON rio), or just hamsh and
friends?**

acme (Plan 9's editor + program shell) is itself a 9P server that
runs inside a rio window and serves `/mnt/acme/*` to its children.
It's the canonical "rio-aware program". Porting it would force
rio's interface to be complete enough for real workloads, and
acme's mouse-driven workflow is the showcase for the file-based
desktop model. But it's a multi-month project. The question is
whether rio gets prioritised purely as a substrate for hamsh +
ported Unix programs, or whether acme is a near-term goal.

**Q4: Wire framing for `/dev/draw` data — strict Plan 9 binary
protocol, or Hamnix-specific simpler variant?**

The strict Plan 9 protocol (§5.2) is well-specified, has a
reference encoder/decoder in 9front, and is what `libdraw` emits.
But it's big-endian-on-the-wire (Plan 9's wart) and has historical
oddities (`allocimage`'s `repl` byte, the `string` op's UTF-16
rune array). A Hamnix-specific variant could be little-endian,
UTF-8-runes, and prune the rarely-used ops. The trade-off is
source-compat with ported Plan 9 programs vs. cleaner design.

V0 leans toward strict Plan 9 for ecosystem compat, but the user
should weigh in before Phase 4 starts.

---

## 10. References

  - Plan 9 4th edition manual, Volume 1: `rio(1)`, `rio(4)`,
    `wctl(7)`, `draw(3)`, `mouse(3)`, `cons(3)`, `snarf(7)`.
  - 9front source: `/sys/src/cmd/rio/` (canonical implementation,
    ~5000 lines of C), `/sys/src/libdraw/`, `/sys/src/9/port/devdraw.c`.
  - Pike, "Acme: A User Interface for Programmers" (1994) — the
    motivating workflow for rio-style file-based UI.
  - Pike, "8½, the Plan 9 Window System" (1991) — rio's
    predecessor; the original design paper.
  - Hamnix internal:
      - `docs/9p.md` — 9P V0 wire spec.
      - `docs/distro-namespaces.md` — Pgrp / rfork / bind / mount
        semantics rio relies on.
      - `docs/native-api.md` — the Plan 9-shape syscall surface.
      - `docs/architecture.md` — Layer 0..5 model; rio lives at
        Layer 5 (apps) speaking through Layer 1 (native syscalls)
        and Layer 4 (the draw byte protocol).
