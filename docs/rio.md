# rio — Hamnix's file-based window system

`rio` is a userspace 9P file server. Each window is a namespace; the
user manipulates the system by reading and writing files inside that
namespace. There is no graphical C API. There is no client library to
link against. A program that wants to draw or read input opens files
under `/dev`, just like every other Plan 9 program. See Plan 9's rio
for the canonical reference (`/sys/src/cmd/rio/` on 9front), and `rio(1)`
/ `rio(4)` in the Plan 9 4th edition manual for the user-facing
contract this document mirrors.

This file is the **design spec** for rio's eventual landing in Hamnix.
**No code is being added in this commit.** The spec is here for review
before the first `rio.ad` is written.

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

## 7. What happens to VTNext-v2

VTNext-v2 (`docs/vtnext-v2.md`, shelved library on the
`agent-abaa05e205853d5bf` worktree at `drivers/vt/vtnext.ad`) is an
**ESC-coded byte-stream wire protocol** between `apps`, `hamwd`,
and a renderer. It has no notion of which window opened which file
— a single `/dev/win/<wid>/draw` is the only window scoping, and
events come back through `/dev/win/<wid>/events`.

This is the **wrong shape** for rio's per-window-namespace model.
The reasons, in order of severity:

  1. **No per-namespace isolation.** VTNext-v2's `/dev/win/<wid>`
     is in a global namespace; window A's process can `open(
     "/dev/win/B/events")` and snoop B's input. There is no
     namespace-private dev tree.

  2. **ESC framing assumes a terminal-emulator transport.** The
     `ESC ] vtn ; … BEL` framing is meant for tunnelling through
     a tty; on a per-window file server it's pure overhead and
     prevents binary draw commands.

  3. **`hamwd` is a separate daemon from "the window system".**
     VTNext-v2 splits drawing (`hamwd`) from compositing
     (renderer); rio collapses them into one 9P server.

  4. **The Plan 9 draw protocol already exists** and is a strict
     superset of what VTNext-v2's drawing layer would need. There
     is no reason to invent a parallel encoding.

**Recommendation: retire VTNext-v2.** The shelved
`drivers/vt/vtnext.ad` library does not merge. `docs/vtnext-v2.md`
gets a one-line preamble pointing at `docs/rio.md` and is kept
for historical reference; the design is not deleted from git, just
not promoted into the kernel.

A secondary option — recycling the ESC-coded framing as the
**internal byte-codec** for `/dev/draw/<id>/data` packets, with each
"command" mapping to one VTNext frame — is rejected. Plan 9's binary
draw protocol is well-specified, has reference implementations, and
is what ported Plan 9 programs (and the future `libdraw` shim) will
emit. Reframing it through VTNext adds an encoder/decoder round-trip
for no gain.

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
      - `docs/vtnext-v2.md` — historical reference for the
        retired window-protocol design (see §7).
