# VTNext-v2 — graphical wire protocol

> **⚠️ SUPERSEDED.** VTNext-v2 was Hamnix's first attempt at a window-
> system wire protocol — an ESC-coded byte stream between apps,
> `hamwd`, and a renderer. The architectural review concluded that a
> single shared byte stream cannot give each window its own private
> `/dev/mouse` / `/dev/cons` / `/dev/draw` (the "moving the mouse in
> window A doesn't appear in window B's mouse file" invariant). The
> replacement design is **[`docs/rio.md`](rio.md)**, which models the
> window system as a Plan 9 9P file server with per-window namespaces.
>
> This document is **kept for historical reference only**. Don't
> implement against it. The codec library briefly built against it
> (`drivers/vt/vtnext.ad`) was never merged to `main` and lives in
> the shelved worktree `.claude/worktrees/agent-abaa05e2…/`.

VTNext-v2 is Hamnix's window-system wire protocol. It carries
vector drawing commands and input events between three parties:

```
+------+        VTNext commands      +-------+    pixels   +----------+
| apps |--- /dev/win/<wid>/draw ---> | hamwd |-- serial -->| renderer |
|      |       (Layer 1)             | Layer | (Layer 4)   | (pygame  |
|      |<-- /dev/win/<wid>/events -- |   3   |<-- events --|  or local|
+------+                             +-------+             |   fb)    |
                                                           +----------+
```

- **Apps** write drawing commands to per-window draw files. They
  don't know about other windows, the screen size, or the renderer.
- **`hamwd`** (display server, Layer 3) owns window registry,
  placement, Z-order, focus, input routing. It speaks VTNext on
  the wire to one renderer.
- **Renderer** (off-system pygame on a laptop, or a local
  framebuffer process) composites, draws chrome, and reports
  input. It is a genuinely dumb pixel pipe — no window logic.

The renderer can live on a phone, a laptop, a Raspberry Pi
running the pygame script, or a local Hamnix process bound to
the EFI GOP framebuffer. The protocol does not assume network
transport.

## Frame format

Inherited from v1, unchanged:

```
Server → Renderer:  ESC ] vtn ; <cmd> ; <param1> ; <param2> ; ... BEL
Renderer → Server:  ESC [ V <kind> ; <param1> ; <param2> ; ... BEL
```

- `ESC` is 0x1B. `BEL` is 0x07.
- Reverse channel uses **`ESC [ V`** to disambiguate from drawing
  commands going the other way. (v1 used `ESC [ M` for xterm-style
  mouse; v2 retires that.)
- Parameters are semicolon-separated ASCII. String parameters are
  double-quoted; quotes inside are backslash-escaped.
- Renderer must tolerate non-protocol bytes between frames — they
  are kernel printk or app stdout and may pass through to a log
  pane. v1 renderers print them; v2 renderers route them to
  `wid=0`.

## Three-tier architecture (reiterated)

| Tier | Where it runs | What it knows | What it doesn't know |
|------|---------------|---------------|----------------------|
| App | any process | its own `wid`s, its content | screen size, other windows, fonts on the wire |
| `hamwd` | Layer 3 daemon | window registry, focus, Z-order, the wire | what's drawn inside any window |
| Renderer | host laptop OR local fb process | how to paint pixels, how to deliver input | what windows mean, who owns them |

If you find yourself reaching for an app→renderer shortcut: stop.
The whole point is that apps go through `hamwd`.

## Handshake

When `hamwd` opens the wire it sends `probe`:

```
ESC ] vtn ; probe BEL
```

The renderer replies:

```
ESC [ V cap ; V2 ; mono=8x16,10x20,12x24,14x28,18x36,24x48 ;
                  mono_bold=8x16,10x20,12x24,14x28,18x36,24x48 BEL
```

Fields:

- `V2` — protocol version. `hamwd` rejects anything older than
  `V2` and falls back to single-window v1 emit mode if the
  renderer responds with bare `V` (back-compat path for
  pre-v2 renderers).
- `mono=<sizes>` — list of font sizes the renderer supports.
  Format `<cell_w>x<cell_h>` in pixels. Apps cache these and
  use them as monospace metrics for layout.
- `mono_bold=...` — same for bold.
- `sans_title=...` — reserved for v2.1 proportional titles.

After the cap line the renderer is expected to acknowledge with
`ready`:

```
ESC [ V ready BEL
```

`hamwd` then emits `win_create wid=0 "boot" ...` for the boot
console and starts forwarding any pending command queue.

## Server → Renderer commands

### Window lifecycle

| Command | Form | Meaning |
|---------|------|---------|
| `win_create` | `win_create <wid> "<title>" <w> <h> [flag1 [flag2 ...]]` | Allocate a window. Flags: `transient`, `modal`, `popup`, `parent=<wid>`, `noresize`. |
| `win_destroy` | `win_destroy <wid>` | Remove the window. |
| `win_place` | `win_place <wid> <x> <y>` | Absolute position. Paired with create; updates allowed for moves. |
| `win_title` | `win_title <wid> "<title>"` | Change titlebar text. |
| `win_resize` | `win_resize <wid> <w> <h>` | DE-decided new size (renderer must keep contents until next `present`). |
| `win_show` | `win_show <wid>` | Make visible. |
| `win_hide` | `win_hide <wid>` | Make invisible (renderer keeps surface). |
| `win_zorder` | `win_zorder <wid1> <wid2> ...` | Full stacking order, bottom to top. |
| `win_raise` | `win_raise <wid>` | Incremental: bring to top. |
| `win_lower` | `win_lower <wid>` | Incremental: send to bottom. |
| `win_cursor` | `win_cursor <wid> <shape>` | Set cursor when over window. Shapes below. |

Cursor shapes: `arrow`, `text`, `crosshair`, `hand`, `wait`,
`resize_h`, `resize_v`, `resize_diag`.

### Drawing

Every drawing command names a window via `<wid>`. The renderer
keeps a backing surface per `wid` and accumulates draws into it.
A `present <wid>` blits that surface to the composited screen.

| Command | Form |
|---------|------|
| `clear` | `clear <wid> <r> <g> <b> <a>` |
| `rect` | `rect <wid> <x> <y> <w> <h> <r> <g> <b> <a>` |
| `rect_outline` | `rect_outline <wid> <x> <y> <w> <h> <thickness> <r> <g> <b> <a>` |
| `line` | `line <wid> <x1> <y1> <x2> <y2> <thickness> <r> <g> <b> <a>` |
| `circle` | `circle <wid> <cx> <cy> <radius> <r> <g> <b> <a>` |
| `text` | `text <wid> <x> <y> <font> <size> <r> <g> <b> "<string>"` |
| `present` | `present <wid>` |

Coordinates are window-local, origin top-left, integer pixels.
Colours are `r;g;b;a` each `0..255`. `a` is alpha; renderers may
ignore it for opaque-only surfaces but must accept the parameter.

`<font>` is a logical name (`mono`, `mono_bold`, eventually
`sans_title`). `<size>` is one of the integers from the cap line.
Other sizes round to the nearest cap-line size.

`text` strings are double-quoted; backslashes escape `"` and `\`.
UTF-8 bytes pass through; the renderer is responsible for glyph
lookup. **No glyph bytes on the wire.**

### Boot console (`wid=0`)

`wid=0` is reserved for the kernel's early printk stream. The
kernel writes `text wid=0 ...` commands directly to the wire
during boot (before `hamwd` exists). Once `hamwd` starts:

1. `hamwd` opens the wire, completes the handshake.
2. The renderer already has whatever boot text it received in
   a default-positioned `wid=0` surface.
3. `hamwd` issues `win_create 0 "boot console" 800 600` and
   `win_place 0 0 0` — taking ownership of wid=0's window-system
   metadata. The renderer must MERGE these onto its existing
   wid=0 surface (i.e., do not clear).
4. wid=0 from then on is a managed window: scrollable,
   non-closeable, focus-able. The user can scroll up to read
   pre-handshake boot messages.

A renderer that has never received any pre-handshake bytes still
shows wid=0 cleanly (it just appears empty until `hamwd` or the
kernel emits draws).

## Renderer → Server events

Format: `ESC [ V <kind> ; <params> BEL`.

### Input (window-local coordinates)

| Event | Form |
|-------|------|
| `key` | `key <wid> <keycode> <modifiers>` |
| `mdown` | `mdown <wid> <x> <y> <btn>` (btn: 1=L, 2=M, 3=R) |
| `mup` | `mup <wid> <x> <y> <btn>` |
| `mmove` | `mmove <wid> <x> <y> <btns>` (btns: bitmask, bit 0=L, 1=M, 2=R) |
| `mwheel` | `mwheel <wid> <x> <y> <delta>` (delta: positive = away from user) |

`<modifiers>` for `key` is a bitmask:

| Bit | Modifier |
|----:|----------|
| 0x01 | Shift |
| 0x02 | Ctrl |
| 0x04 | Alt |
| 0x08 | Super (Win/Cmd) |
| 0x10 | CapsLock active |
| 0x20 | NumLock active |

`<keycode>` is either:

- A single byte 0x20..0x7E for ordinary printable ASCII (the
  byte value itself), OR
- A special-key code from the table below.

### Special key codes

Special codes are emitted as ASCII decimal for clarity over
the wire. Renderers must NOT send raw control bytes for these —
the modifier flags + special code is the canonical form.

| Decimal | Name |
|--------:|------|
| 256 | Escape |
| 257 | Backspace |
| 258 | Tab |
| 259 | Enter |
| 260 | Insert |
| 261 | Delete |
| 262 | Home |
| 263 | End |
| 264 | PageUp |
| 265 | PageDown |
| 266 | ArrowLeft |
| 267 | ArrowRight |
| 268 | ArrowUp |
| 269 | ArrowDown |
| 270..281 | F1..F12 |
| 282 | PrintScreen |
| 283 | ScrollLock |
| 284 | Pause |
| 285 | Menu |
| 286..289 | Reserved for media keys |

For backward compatibility with v1's xterm-mouse `ESC [ M`
encoding, v2 renderers MAY still send `ESC [ M ...` and `hamwd`
SHOULD interpret it as `mdown wid=focused x y btn` — but new
renderers should not emit it.

### Window management (renderer-initiated)

| Event | Form | Meaning |
|-------|------|---------|
| `close` | `close <wid>` | User clicked the close box. |
| `drag` | `drag <wid> <new_x> <new_y>` | User dragged the titlebar. `hamwd` acks with `win_place`. |
| `resize_req` | `resize_req <wid> <new_w> <new_h>` | User dragged a resize handle. `hamwd` acks with `win_resize`. |
| `focus` | `focus <wid>` | Focus arrived. |
| `blur` | `blur <wid>` | Focus left. |
| `expose` | `expose <wid>` | The window became visible again (or was uncovered). The owning app should re-emit all draws for `<wid>`. |
| `ready` | `ready` | Sent once at startup after the cap line. |
| `screen_geom` | `screen_geom <w> <h>` | Renderer reports current display dimensions. Sent once at handshake and again on screen-size change. `hamwd` uses this for window-placement decisions. |

### Renderer error reporting

```
ESC [ V error ; <code> ; "<message>" BEL
```

Codes (decimal):

| Code | Meaning |
|-----:|---------|
| 1 | Unknown command name |
| 2 | Bad parameter count |
| 3 | Bad parameter format |
| 4 | Unknown wid |
| 5 | Drawing past window bounds |
| 6 | Out of memory in renderer |
| 7 | Out of supported font size |

`hamwd` logs errors to `/dev/win/log` (a per-renderer log file).
A renderer SHOULD continue running after emitting an error;
`hamwd` MAY tear down the offending wid.

## Font handling — 100% client-side

Glyphs **never** cross the wire. Apps and `hamwd` know:

1. Logical font names (`mono`, `mono_bold`).
2. Allowed sizes (from cap line).
3. Per-(font, size) cell dimensions (from cap line).

Apps lay out text assuming monospace: a string `"hello"` at
`(mono, 14)` occupies `5 * cell_w_14` pixels wide by `cell_h_14`
tall. The renderer's local font may be 1-2 px off; that's
acceptable.

A renderer MUST honour the sizes it advertises. If it later
finds it can't render at size 24, it MAY emit:

```
ESC [ V cap ; V2 ; mono=8x16,10x20,12x24,14x28,18x36 ; ... BEL
```

— a fresh cap line invalidates the previous one. `hamwd`
re-distributes the new dimensions to apps via a `cap_update`
event on `/dev/win/<wid>/events`.

Bold-vs-regular is a separate logical font name (`mono_bold`),
not a parameter on `text`. Renderers must be able to render
both at every advertised size.

## Damage model — implicit

There are **no damage rectangles** in v2. The model is:

1. Apps redraw what changed by emitting commands.
2. Commands accumulate in the renderer's per-window backing
   surface.
3. `present <wid>` blits that surface to the composited screen.
4. On `expose <wid>`, the owning app must re-emit all draws for
   that window. The renderer cleared the backing surface before
   sending `expose`.

The protocol does NOT require apps to remember what they drew.
Apps that want efficient redraw maintain their own scene graph;
apps that don't, redraw from scratch each `expose`. Either works.

A consequence: `clear <wid> ...` resets the surface and is the
only way to wipe a window without re-receiving an `expose`.

## Coordinate system and units

- Pixels. Integer. Origin top-left of each window's client area.
  Titlebars and chrome are NOT included in window-local
  coordinates — apps draw in the content rectangle.
- Window dimensions in `win_create` / `win_resize` are the
  content rectangle. The renderer adds chrome around it.
- Coordinates may legally extend past the window's current size
  — drawing is clipped by the renderer.

## Reliability and ordering

- Drawing commands for a single `wid` arrive in the order the
  app wrote them (single-fd writes are serialised at `hamwd`).
- Drawing commands for **different** `wid`s have NO ordering
  guarantee with respect to each other across the wire.
- `present <wid>` is a barrier ONLY for `wid` — there is no
  global flush. To synchronise two windows' updates, an app
  must coordinate at Layer 5 (typically via shared state and
  paired `present`s in quick succession).
- The wire is reliable byte-stream — `hamwd` uses TCP or a
  serial line that guarantees no drops.
- If the renderer disconnects mid-frame, `hamwd` discards the
  partially-emitted command and re-emits everything from scratch
  on reconnect via `expose` events to all surviving windows.

## hamwd-internal: `/dev/win/*` tree

`hamwd` exposes the following 9P tree (Layer 1 file paths):

```
/dev/win/
    ctl                # global control (create/destroy/list)
    log                # renderer error log (read-only)
    screen             # current screen geometry (read-only)
    <wid>/
        ctl            # per-window control (title/resize/cursor)
        draw           # write VTNext drawing commands (no wid prefix needed)
        events         # read input + management events
        present        # write any byte to flush
        title          # read+write title string
        status         # read current state: pos, size, focus
```

### `/dev/win/ctl` commands

Apps write text commands; reads echo recently-created window
ids and errors.

```
create <w> <h> "<title>" [flag ...]   → wid as ASCII decimal
destroy <wid>                          → "ok\n" or "error: <msg>\n"
list                                   → one line per window: <wid> <title>
```

### `/dev/win/<wid>/draw` semantics

A write to this file is a textual VTNext drawing command **without**
the `wid` argument (the file's path already names the window) and
**without** the framing bytes (the daemon adds `ESC ] vtn ; ... ;
... BEL` on the wire side). Example:

```
write(draw_fd, "rect 0 0 800 600 200 200 200 255\n", 33)
write(draw_fd, "text 10 30 mono 14 0 0 0 \"Hello\"\n", 33)
```

`hamwd` translates each line into the wire form:

```
ESC ] vtn ; rect ; 17 ; 0 ; 0 ; 800 ; 600 ; 200 ; 200 ; 200 ; 255 BEL
ESC ] vtn ; text ; 17 ; 10 ; 30 ; mono ; 14 ; 0 ; 0 ; 0 ; "Hello" BEL
```

(Wire commands inject the `<wid>` field after the command name.
File-side text uses the existing v1 spelling without wid for
ergonomics.)

### `/dev/win/<wid>/events` semantics

`read` returns one event per call. Each event is a single line
(no trailing `;`) with the renderer's `kind` followed by params:

```
key 97 0            # 'a' pressed, no modifiers
mdown 100 50 1      # left-click at (100, 50) in window-local
expose              # this window needs full redraw
```

A blocked `read` wakes when an event arrives.

## Local-framebuffer renderer (v3 scope note)

The same protocol works against a local renderer that draws into
the EFI GOP framebuffer (the same one `drivers/video/console/
fb_text.ad` uses for the boot console). Out of scope for v2
implementation, but the protocol design must not foreclose it.
Specifics:

- The renderer is a normal Hamnix process at Layer 5, not a
  kernel driver.
- It opens `/dev/fb/0` (a future device file Layer 3 exposes for
  the framebuffer) and writes pixels there.
- It connects to `hamwd` via a local pipe (or `/srv/hamwd`),
  identical wire bytes as the network case.
- It MAY use SIMD font rasterisation (kernel exports `/dev/cpu/0/
  features` to advertise SSE/AVX availability) or fall back to
  scalar.
- No GPU driver, no DRM, no Mesa, no Wayland. The renderer is
  ~2000 lines of Adder.

The point of this note: a Hamnix box with no laptop attached can
still run hamwd + a local renderer + a graphical app and get a
windowed desktop. The wire format is the same. The renderer
process is swappable.

## Reference v1→v2 deltas

For an implementer porting the existing pygame renderer
(`vtnext/renderer.py` in earlier Hamnix MCU-era trees; spec
preserved here for reference):

| v1 | v2 |
|----|----|
| Single fullscreen surface; no wids | Per-window surfaces keyed by `<wid>` |
| Reverse channel `ESC [ M ...` (xterm mouse) | Reverse channel `ESC [ V <kind> ; ...` |
| `probe` reply: `V` | `probe` reply: `V2 mono=... mono_bold=...` |
| Drawing commands have no wid | Every drawing command has `<wid>` as first param |
| `viewport` to resize | `win_resize` per-window; renderer reports screen via `screen_geom` |
| No window lifecycle | Full lifecycle: create/destroy/place/title/resize/show/hide/zorder/raise/lower/cursor |
| No focus or expose | `focus`/`blur`/`expose` events |
| Single set of input events | Per-window input events with `<wid>` |

A v2-aware renderer SHOULD detect v1 clients (single trailing
`V` on probe, no wid in commands) and emulate single-window
mode by maintaining one implicit `wid=1` surface. This buys
zero-friction migration during Phase D.

## What this protocol does NOT include

- **No image blits.** `text` and the vector primitives are the
  whole drawing surface in v2. v2.1 adds `blit` for an RGB
  buffer attachment (out of scope here).
- **No font upload.** Fonts are local to the renderer, always.
- **No glyphs on the wire.** `text` carries the string; the
  renderer rasterises.
- **No shaders.** No GPU offload. No compute primitives.
- **No clipboard.** Clipboard is a Layer 3 service (`/dev/clip`)
  not a wire concept.
- **No drag-and-drop file transfer.** A Layer 3 service can
  expose the clipboard as files; the wire only carries pixels
  and input.
- **No video.** A v2.1+ extension could add a `video` command
  taking a 4:2:0 frame, but v2 is text + vectors only.

## Implementation status

- **Phase D skeleton (in tree, M16.x):** `user/hamwd.ad` ships a
  Hamnix userland daemon that implements the wire-emission side of
  this protocol for `probe`, `win_create`, `win_destroy`,
  `present`, and `text`. The daemon owns a 16-slot in-process
  window registry (wid=0 reserved for the boot console per "Boot
  console (`wid=0`)" above), parses text commands written to
  stdin, and emits framed `ESC ] vtn ; <cmd> ; ... BEL` packets
  to stdout. Two driving modes: one-shot (`hamwd create 800 600
  Test`) and daemon (`echo "create ..." | /bin/hamwd`). Verified
  end-to-end via `scripts/test_hamwd.sh`.
- **What is NOT yet shipped (Phase D follow-ups):**
  - Real `/srv/hamwd` posting. The Plan 9 idiom — daemon creates
    `/srv/hamwd` as a channel handle that clients `open` and pass
    to `mount(srvfd, -1, "/dev/win", MREPL, "")` — needs a kernel-
    side `/srv/` post-and-attach surface plus a 9P client inside
    the chan resolver (`sys/src/9/port/chan.ad`'s
    `chan_resolve_prefix`). The skeleton documents this gap; the
    smoke test exercises the mount() CALL SHAPE against any open
    fd (the same contract `test_p9mount.ad` exercised at M16.107)
    so the architectural call sites are in place. Once the
    resolver learns to walk a SRV-kind chan through the stored
    srvfd, `mount(open("/srv/hamwd"), -1, "/dev/win", MREPL, "")`
    starts driving real bytes through hamwd unchanged.
  - Renderer handshake reply parse. `hamwd` emits `probe`; with no
    renderer wired to `qemu -serial stdio` no `cap` line comes
    back. A real handshake is wired once a pygame (or local
    framebuffer) renderer is attached.
  - Reverse-channel input. `ESC [ V <kind> ; ...` lines from the
    renderer aren't demuxed back to per-window `/dev/win/<wid>/
    events` yet. Wire format is pinned; parser is straightforward.
  - Full drawing command set (`rect`, `rect_outline`, `line`,
    `circle`, `clear`, `win_place`, `win_resize`, `win_show`,
    `win_hide`, `win_zorder`, `win_raise`, `win_lower`,
    `win_cursor`, `win_title`). Wire frame helpers in `hamwd.ad`
    generalise to any of these by adding a parse arm; this is
    incremental work the skeleton unlocks.
  - hamwd as PID 2 from `/etc/rc`. Today it runs as a foreground
    invocation under hamsh. Auto-launch via `/etc/rc` is a
    follow-up once `/srv/hamwd` posting lets the daemon survive
    across client invocations.

The architectural payoff of this skeleton: Phase D's promise that
**Layer 3 services use only Layer 1** is no longer a rule on paper.
A real userland `.ad` binary now emits VTNext frames using
`open` / `write` / `read` / `mount` and nothing else.

## References

- v1 renderer source (legacy, for historical context): the
  pygame `VTNextRenderer` class. Frame format and `present`
  semantics preserved; everything else expanded.
- ANSI escape sequence conventions (CSI = `ESC [`, OSC = `ESC ]`)
  drove the bracket choice — `ESC ]` (OSC) is well-precedented
  for application-defined commands; `ESC [` (CSI) for cursor
  and control.
- `docs/architecture.md` — where `hamwd` (Layer 3) and the renderer
  (Layer 5) live in the layered model; the migration plan's Phase D
  is when this protocol actually gets implemented in code.
- `docs/native-api.md` — the `/dev/win/*` filesystem shape and
  the `ctl`-file discovery dance this protocol completes.
