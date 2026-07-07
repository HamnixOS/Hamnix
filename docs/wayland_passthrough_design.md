# Wayland Passthrough — modern-web-browser bring-up design

**Status:** design + feasibility scoping (2026-07-01). NOT an implementation.
This document is the contract for adding a **Wayland server front-end** to
Hamnix's native scene compositor so that Wayland *clients* running in the
Linux-ABI namespace (first `weston-info`/`weston-terminal`, then XWayland,
then Firefox/Chromium) connect over a `$WAYLAND_DISPLAY` unix socket and
have their surfaces composite into ordinary Hamnix DE windows.

We implement **one** protocol (a minimal Wayland server) and get both
Wayland-native *and* X11 apps — the latter for free via **XWayland**, an X
server that is itself a Wayland client.

All file:line citations are against the tree at time of writing.

---

## 0. TL;DR verdict

- **Wire protocol (byte stream) across the ns boundary: FEASIBLE today.**
  The AF_UNIX endpoint pool in `linux_abi/u_unixsock.ad` is a *kernel-global*
  byte conduit (module-scope BSS arrays, not per-process:
  `u_unixsock.ad:125-158`), so a native/in-kernel compositor front-end can be
  the listening peer of a Linux-ns client with no new transport.
- **shm buffer sharing across the ns boundary: NOT feasible as-is — this is
  THE gating risk.** Wayland clients hand the compositor pixel memory by
  passing a `wl_shm` pool **fd** over the socket in an `SCM_RIGHTS` ancillary
  message via `sendmsg(2)`. `sendmsg`(46)/`recvmsg`(47) are declared
  (`u_syscalls.ad:1265-1266`) but **NOT dispatched** (absent from the dispatch
  table around `u_syscalls.ad:15907-15932`), so they return `-ENOSYS`. There
  is **no `SCM_RIGHTS` / ancillary-data path anywhere** (`grep` finds only a
  historical mention in `u_pidfd_getfd.ad:4`). **However**, the substrate to
  *implement* it cheaply already exists: `memfd_create` is real and backed by
  anonymous tmpfs (`u_memfd.ad:117` → `vfs_open_memfd` → `tmpfs_create_anon`),
  and **MAP_SHARED writable tmpfs mappings already share the same physical
  frames across processes** (`mm/vma.ad` §shared-pagecache, `:3342-3355`,
  `:3491-3507`; `tmpfs_page_phys` imported at `fs/vfs.ad:329`). So the missing
  piece is *plumbing* (SCM_RIGHTS parse + an fd→backing-object→phys-pages
  bridge into the native front-end), **not** new MM/IPC architecture.
  **Verdict: feasible, but Phase 1 is blocked until we add SCM_RIGHTS fd
  passing (or the fd-less shm-pool shim described in §4.3).**

Phases: **(1)** socket front-end + `wl_shm` buffer → v2 blit backbuffer +
minimal `wl_compositor`/`wl_surface`; **(2)** `wl_seat` input; **(3)**
`xdg-shell` window management; **(4)** XWayland → X11 apps; **(5)**
Firefox/Chromium.

---

## 1. Architecture

```
  ┌─────────────────────── Linux-ABI namespace (real Debian binaries) ────────────────────┐
  │                                                                                        │
  │   weston-terminal / XWayland / firefox   (libwayland-client)                           │
  │        │  wl wire protocol (binary msgs)          │  wl_shm pool fd (SCM_RIGHTS)        │
  │        │                                          │  memfd_create + mmap MAP_SHARED     │
  └────────┼──────────────────────────────────────────┼─────────────────────────────────── ┘
           │  connect() to $WAYLAND_DISPLAY            │  sendmsg(fd, SCM_RIGHTS)
           ▼  (AF_UNIX SOCK_STREAM, pathname          ▼
        ┌──────────────────────────────────────────────────────────────────┐
        │  AF_UNIX endpoint pool  (linux_abi/u_unixsock.ad — KERNEL-GLOBAL)  │
        │  byte ring conduit  +  [NEW] SCM_RIGHTS ancillary carrier          │
        └───────────────┬──────────────────────────────────┬───────────────┘
                        │ byte stream                       │ passed fd → tmpfs anon slot → phys pages
                        ▼                                    ▼
        ┌──────────────────────────────────────────────────────────────────┐
        │  WAYLAND SERVER FRONT-END  (native Hamnix component)               │
        │  wl_display / wl_compositor / wl_surface / wl_shm / wl_seat /      │
        │  xdg-shell object graph + wire (de)serialiser                      │
        │                                                                    │
        │  per wl_surface  ⇄  one Hamnix window (wid)                        │
        └───────────────┬──────────────────────────────────┬───────────────┘
       newwindow / ctl  │                                   │  'B' blit + 'D' dirty
       /event /keys read│                                   ▼
        ┌───────────────▼──────────────────────────────────────────────────┐
        │  devwsys scene compositor  (sys/src/9/port/devwsys.ad)            │
        │  v2 BLIT PROTOCOL: per-window RGBA8888 backbuffer (#442)          │
        │  z-order + focus + hit-test  →  rasterize/z-blit  →  /dev/fb      │
        └──────────────────────────────────────────────────────────────────┘
```

Key insight: the **wl_surface ⇄ Hamnix window** mapping lands on machinery
that already exists. Wayland surfaces are *raw pixel buffers*, and Hamnix
already has a raw-pixel-buffer window path — the **#442 v2 blit protocol**
(§2). We do **not** need to invent a new scene node type; we drive the
existing one.

---

## 2. The scene compositor: the raw-buffer impedance match

The scene-file architecture (`docs/de_scene_file_arch.md`) publishes a
*text display list* per window (`fill`/`text`/`rect`/`image`, grammar at
`de_scene_file_arch.md:76-87`). That is the wrong shape for Wayland, which
delivers opaque pixel buffers, not drawing commands.

**But a second path already exists and is exactly right.** The #442
"RIO-faithful blit protocol" (`devwsys.ad:6314-6350`) lets a client render
into a **kernel-held per-window backbuffer** and submit raw pixels:

- Wire verbs on `/dev/wsys/<wid>/draw/ctl` (`devwsys.ad:6326-6337`):
  - `'B' x0 y0 x1 y1 fmt <pixels>` — opaque blit of a pixel rect.
  - `'D' x0 y0 x1 y1` — dirty-rect invalidation (drives recomposite).
  - `'C' hot_x hot_y w h fmt <pixels>` — cursor sprite.
- Pixel formats (`devwsys.ad:6352-6354`): `RGBA8888=1`, **`BGRA8888=2`**,
  `A8=3`. Wayland's default `WL_SHM_FORMAT_ARGB8888`/`XRGB8888` are
  little-endian **B,G,R,A in memory** → maps **directly** to
  `WSYS_BLIT_FMT_BGRA8888`. No conversion in the hot path.
- Backbuffer: lazily-allocated 4 MiB block per wid, `1280×800` RGBA8888
  internal, stride 5120 (`devwsys.ad:6356-6376`,
  `_wsys_backbuffer_ensure` `:6421`). Ingestion +
  format-convert loop: `_wsys_blit_store_rect` `:6620-6704` (the
  BGRA→internal-RGBA path is `:6680-6685`).
- Per-window protocol version gate: `wsys_win_version` (`:6380`),
  `wsys_win_version_get` (`:6408`); a window opts into the blit path by
  writing `version 2` to wctl (`:5950-5973`).
- Damage/serial: `_wsys_bb_dirty_add` (`:6595`), `wsys_bb_serial` (`:6391`),
  `wsys_bb_dirty_get` (`:6487`) / `wsys_bb_dirty_clear` (`:6505`) — the
  compositor's per-frame walk reads these to repaint only changed windows.

**Mapping.** On `wl_surface.attach(buffer)` + `wl_surface.commit`, the
front-end issues one `'B'` blit of the committed shm region into the
surface's window backbuffer, plus a `'D'` for the damaged rect (from
`wl_surface.damage`), then sends `wl_buffer.release` back to the client.
That is one memcpy-class conversion per commit — the same cost the DE's own
apps pay.

**IMPORTANT GAP — the v2 backbuffer is not on the current composite path.**
The kernel now owns both the rasterizer (`_wsys_rasterize_window` `:7971`)
and the z-blit compositor (`_wsys_scene_present_locked` `:8497`,
`_wsys_present_window` `:8233`), driven from the `commit` ctl verb
(`devwsys_winctl_write` commit arm `:7337-7380`) and the mouse router. That
composite path blits only the per-window **scene cache**
(`_wsys_layer_fb_get`); the v2 blit backbuffer is presently consumed *only*
by an older/userland compositor via the `<wid>/bbstate`
(`devwsys_bbstate_read` `:6880`) + `<wid>/backbuffer`
(`devwsys_backbuffer_read` `:6925`) files. So a `'B'` blit lands in the
backbuffer but is **not drawn to `/dev/fb`** by the in-kernel present path
today. Wiring Wayland surfaces onto the blit path therefore requires one of:
  - **(a)** add a `buffer`/`image` scene opcode in `_wsys_rast_line`
    (`:8178`, where `image` is currently a parse-and-ignore stub) that
    composites the window's v2 backbuffer (or a named tile) into the scene
    cache during rasterization; or
  - **(b)** teach `_wsys_present_window` (`:8233`) /
    `_wsys_scene_present_locked` (`:8497`) to z-blit the v2 backbuffer
    alongside the scene cache.
  Option (a) keeps everything on the single scene-present pipeline (one
  damage/z path) and is the recommended target. Either way this is a small,
  contained devwsys change — the ingest + format-convert
  (`_wsys_blit_store_rect` `:6620`) and damage tracking
  (`_wsys_bb_dirty_add` `:6595`) already exist; only the *present* step is
  missing.

Also note: `docs/de_scene_file_arch.md` §7 describes the compositor as
userland (`user/hamUId.ad`); the in-tree reality moved it into the kernel
(`devwsys.ad`), serialized by `wsys_present_lock`. Cite the code, not the
doc, for current behaviour.

**Window lifecycle** (`devwsys.ad`):
- Create: write `newwindow` to `/dev/wsys/ctl` →
  `devwsys_ctl_write` (`:2884`), verb match (`:2908`); the assigned wid is
  stashed per-pid for readback (`:2704-2710`). A process may `newwindow`
  repeatedly for multiple surfaces (`:2895`).
- Per-window files (`de_scene_file_arch.md:49-60`): `scene`, `ctl`,
  `event`, `winid`; the blit path adds `draw/ctl`.
- z-order / stacking: `wsys_win_z`, raise via `_wsys_raise` (`:9566`,
  app-band clamped below chrome floor z<100); first commit auto-maps +
  raises + focuses once (`:7353-7367`, guard `wsys_win_mapped` `:7029`).
- Recompose is event-driven off the dirty rect; writing pixels + `'D'` is
  what triggers a repaint.

**Conclusion:** no new scene node type is required. The Wayland front-end is
a *producer* on the existing v2 blit path. This is the single most important
finding for feasibility — the hardest-looking piece (raw buffers vs display
lists) is already solved.

---

## 3. Input: /dev/mouse + keyboard → wl_seat

Everything a `wl_seat` needs is already cooked server-side; the front-end
consumes per-window event lines rather than re-implementing hit-testing.

- **Mouse source:** `drivers/input/auxmouse.ad` (`MouseEvent` `:142-158`);
  device server `/dev/mouse` `devmouse.ad:114-190` emits
  `"<dx> <dy> <buttons> <dz>\n"` (abs form appends `<x> <y> ... 1\n`).
- **Keyboard source:** `drivers/input/atkbd.ad` translates Set-1 scancodes to
  **cooked ASCII** (`kbd_rx_push` `:716`, `kbd_rx_pop` `:732`); `/dev/cons`
  serves the byte stream (`devcons.ad:241`, `:340`). While the DE is live the
  physical keyboard is routed to the compositor, not `/dev/cons`
  (`devcons.ad:294`).
- **Focus:** single global `wsys_focus_wid` (`devwsys.ad:9100`); setter
  `_wsys_set_focus` (`:9548-9563`) emits `f out`/`f in`; policy
  click-vs-sloppy per window (`wsys_wctl_focus` `:5871`,
  `wsys_wctl_focus_mode` `:5917`).
- **Hit-test / routing:** `_wsys_hit_test` (`:9459`) returns top-most wid;
  `_wsys_route_common` (`:9830-10143`) computes press/release edges, handles
  chrome, and forwards window-local pointer events; abs/rel entry points
  `wsys_route_mouse_abs` (`:9744`) / `_rel` (`:9770`).
- **Per-window event streams the front-end reads:**
  - `/dev/wsys/<wid>/event`: `"m <lx> <ly> <buttons> <dz>\n"`
    (`_wsys_evt_emit_pointer` `:9372-9384`, window-local coords) → `wl_pointer`
    motion/button/axis.
  - `/dev/wsys/<wid>/keys`: `"d <code>\n"` (`wsys_route_key_byte`
    `:10188-10210`); richer `"k <down|up> <keysym> <mods>\n"`
    (`wsys_route_key` `:10146`) → `wl_keyboard` key.
  - `"f in"`/`"f out"` (`_wsys_evt_emit_focus` `:9387`) →
    `wl_keyboard.enter`/`leave`.
  - `"r <w> <h>"` (`_wsys_evt_emit_resize` `:9401`) → `xdg_toplevel.configure`.

**Mapping cost:** low. The one real gap is a **keymap**: Hamnix delivers
cooked ASCII bytes, whereas `wl_keyboard` wants an XKB keymap + evdev
keycodes + a `keymap` fd (again fd-passing — see §4.4). Phase 2 must either
ship a fixed XKB keymap blob and translate ASCII→keycode, or (simpler)
publish the `"k <down|up> <keysym> <mods>"` richer form which already carries
a keysym.

---

## 4. The fd/Chan + ns boundary — the gating analysis

### 4.1 What exists

- **fd model:** fds are marks in the process fd table
  (`fs/vfs.ad:10-50`); most real files are `FD_CHAN_MARK` fds carrying an
  inline Chan id (`:14-25`). Sockets are `FD_SOCKET_MARK` fds
  (`vfs_alloc_socket_fd`), whose `fd_buf` either indexes an
  `fs/socket_state.ad` record (AF_INET) or carries an **AF_UNIX tag**
  (`u_unixsock.ad:92-99`, `afunix_fdbuf_for_ep` `:264`).
- **AF_UNIX:** full `socket`/`bind`/`listen`/`connect`/`accept`/`socketpair`
  + stream & datagram I/O (`u_unixsock.ad:614-939`), abstract + pathname
  namespaces (`_afu_parse_sun` `:362`). Dispatched at
  `u_syscalls.ad:15907-15932`. **The endpoint pool is module-global BSS**
  (`u_unixsock.ad:125-158`) — so it is a *single-box* conduit shared by every
  caller, including a would-be native peer.
- **Shared memory:** `memfd_create(2)` is real (`u_memfd.ad:79-118` →
  `vfs_open_memfd` → anonymous tmpfs slot). tmpfs `MAP_SHARED` writable
  mappings share the **same physical frames** across processes
  (`mm/vma.ad:3342-3355`, fault resolver `:3491-3507`, imported
  `tmpfs_page_phys`/`tmpfs_extend_size` at `fs/vfs.ad:327-329`). This is the
  coherence guarantee `apt`'s pkgcache relies on, and it is exactly what a
  wl_shm pool needs.

### 4.2 What is missing (the gate)

- **`sendmsg`/`recvmsg` are not dispatched** — declared at
  `u_syscalls.ad:1265-1266`, no handler, no `_u_sendmsg`/`_u_recvmsg`
  (`grep` returns nothing) → `-ENOSYS`.
- **No `SCM_RIGHTS`, no `struct msghdr`/`cmsghdr` parsing anywhere.** There is
  no ancillary-data carrier on an AF_UNIX endpoint (the ring in
  `u_unixsock.ad` moves *bytes only*).
- **No cross-namespace fd→object bridge.** Even with SCM_RIGHTS parsing, an
  fd number is meaningful only inside a Linux-ns fd table; the native
  front-end is not a Linux-ns process with an fd table, so "receiving the fd"
  must instead mean **resolving the passed fd to its tmpfs backing slot and
  mapping that slot's physical pages** into the front-end.

### 4.3 Verdict + the two implementable routes

**Verdict: FEASIBLE, but not as-is — Phase 1 is blocked on new fd-passing
code.** No fundamental architectural blocker exists because (a) the wire path
already works (global AF_UNIX), and (b) the physical-page-sharing substrate
already works (tmpfs MAP_SHARED coherence). The gap is glue.

Two routes, pick per effort:

- **Route A — real SCM_RIGHTS (protocol-faithful, unblocks X11 too).**
  1. Dispatch `sendmsg`/`recvmsg` (`u_syscalls.ad`), parse `struct msghdr` +
     `cmsghdr` for `SCM_RIGHTS`.
  2. Extend the AF_UNIX endpoint with a small **pending-fd queue** alongside
     the byte ring (`u_unixsock.ad`): a `sendmsg` with `SCM_RIGHTS` enqueues
     the *backing object* (tmpfs anon slot id + size), not the fd number.
  3. On the receive side, if the receiver is a Linux-ns process, allocate a
     new fd bound to the same tmpfs slot (dup semantics). If the receiver is
     the **native front-end**, expose an in-kernel `afunix_recv_scm()` that
     returns the tmpfs slot id so the front-end can `tmpfs_page_phys`-map the
     pool. This is the general fix and is what XWayland/GTK/Chromium expect;
     it also pays back the missing-syscall debt broadly (dbus, systemd, GTK
     all pass fds).

- **Route B — fd-less shm-pool shim (fastest Phase-1 bring-up).**
  Because tmpfs shared mmap is coherent, we can side-step SCM_RIGHTS for the
  *specific* `wl_shm.create_pool` path: intercept the pool creation in the
  front-end and have the client-side pool live at a **known named tmpfs path**
  (e.g. `/dev/shm/wl-pool-<id>`) that both the client (already `mmap`ed) and
  the front-end (`open`+`tmpfs_page_phys`) map. This requires a tiny shim
  (an `LD_PRELOAD` in the Linux ns, or a patched `libwayland`/mesa `wl_shm`
  allocator) so the pool fd is a *named* tmpfs file rather than an anonymous
  memfd. Cheaper to stand up, but it is a per-client hack that will **not**
  carry XWayland/Chromium — so Route B is a Phase-1 proof only; Phase 4+
  requires Route A.

**Recommendation:** do Route B to prove the pixel pipeline in Phase 1 if
Route A slips, but plan for Route A as the real deliverable — it is on the
critical path for XWayland and browsers regardless.

### 4.4 Secondary fd-passing needs

`wl_keyboard.keymap` and `wl_drm`/`linux-dmabuf` also pass fds. Phase 2's
keymap can be worked around (send a keymap the client reads inline, or use
the keysym event form). `linux-dmabuf` (zero-copy GPU buffers) is a Phase-5
concern — see §7; we plan to force **shm/software** buffers for
Firefox/Chromium and avoid dmabuf entirely.

---

## 5. Wayland server pieces — native vs bridge

**Decision: implement the Wayland wire protocol NATIVELY in the Hamnix
front-end.** Reasons:

- The protocol is a compact, well-specified binary format (object-id +
  opcode + args over the unix socket). A minimal server is a bounded amount
  of code, and it keeps the pixel/input path in-tree where it can reuse
  `devwsys` primitives directly (no second copy of every buffer).
- The alternative — running upstream `libweston`/`wlroots` as a Linux-ns
  helper that then re-forwards into `devwsys` — doubles the buffer copies and
  still needs the SCM_RIGHTS fix to receive client buffers, so it buys
  nothing on the gate while adding a huge dependency.

Minimal interface set for Phase 1–3:
- `wl_display` / `wl_registry` — bind bootstrap; advertise globals.
- `wl_compositor` — `create_surface`, `create_region`.
- `wl_surface` — `attach`, `damage`, `frame`, `commit` → drive the v2 blit.
- `wl_shm` / `wl_shm_pool` / `wl_buffer` — pool from a passed fd (§4.3);
  `create_buffer(offset,w,h,stride,format)`; `release` back to client.
- `wl_seat` / `wl_pointer` / `wl_keyboard` — from §3 event streams.
- `xdg_wm_base` / `xdg_surface` / `xdg_toplevel` — window role, title,
  configure/ack, min/max/close → map to `newwindow`, wctl geometry, chrome,
  and the `"r"`/`"f"` event lines.

The socket lives at `$WAYLAND_DISPLAY` (default `wayland-0`) under
`$XDG_RUNTIME_DIR`; the front-end `bind`s that pathname via the AF_UNIX
listener (`afunix_bind`/`afunix_listen`, `u_unixsock.ad:627`,`:652`) and
Linux-ns clients `connect` to it by name (`afunix_connect` `:667`).

**Where the front-end lives:** a native Hamnix file-server/daemon (Plan-9
shape) that (a) owns the AF_UNIX listener via the in-kernel `afunix_*` API,
(b) opens `/dev/wsys/ctl` + per-wid files, and (c) maps client shm pools via
`tmpfs_page_phys`. It runs as a normal DE-band process; it needs no hostowner
because window ownership already works for non-hostowner PIDs
(`de_scene_file_arch.md:63-66`).

---

## 6. Phased plan

### Phase 1 — socket front-end + shm buffer → blit backbuffer
**Goal / bring-up target:** `weston-info` enumerates globals; `weston-terminal`
opens and shows a window whose pixels are visible in `/dev/fb`.
- **Files:** `linux_abi/u_syscalls.ad` (dispatch `sendmsg`/`recvmsg`),
  `linux_abi/u_unixsock.ad` (SCM_RIGHTS pending-fd/backing-object queue +
  `afunix_recv_scm`), a **new** native front-end
  (e.g. `user/waylandd.ad`), `fs/vfs.ad`/`fs/tmpfs.ad` (expose an
  fd→tmpfs-slot resolver + `tmpfs_page_phys` map for the front-end), and
  **`sys/src/9/port/devwsys.ad`** to put the v2 backbuffer on the composite
  path (§2 gap — add the `buffer` opcode in `_wsys_rast_line` `:8178` **or**
  z-blit the backbuffer in `_wsys_present_window` `:8233`).
- **Reuse:** v2 blit path (`devwsys.ad:6314-6704`), `newwindow`
  (`devwsys.ad:2884`), tmpfs shared-mmap coherence
  (`mm/vma.ad:3342-3507`), memfd (`u_memfd.ad`).
- **Risks:** the SCM_RIGHTS gate (§4) — mitigate with Route B if it slips;
  the **v2-backbuffer-not-on-composite-path gap** (§2 — must land the
  present-side wiring before any pixels appear); format mismatch (validate
  ARGB8888→BGRA8888 byte order on real client output); backbuffer 1280×800
  cap vs large windows.
- **Test:** boot under KVM/OVMF, `enter linux`, run `weston-info` (must list
  `wl_compositor`,`wl_shm`,`wl_seat`,`xdg_wm_base`), then `weston-terminal`;
  gate on a pixel-diff PNG of `/dev/fb` showing the terminal (the DE
  render-check is already pixel-diff, per project memory).

### Phase 2 — wl_seat input
**Goal:** type into `weston-terminal`, click/move cursor.
- **Files:** front-end (`wl_seat`/`wl_pointer`/`wl_keyboard`), maybe a fixed
  XKB keymap asset.
- **Reuse:** per-wid `/event`+`/keys` streams (§3), focus (`wsys_focus_wid`).
- **Risks:** keymap/keycode translation (ASCII→evdev/XKB); keymap-fd passing
  (§4.4); axis/scroll units.
- **Test:** scripted keystrokes via the serial/DE input path land as visible
  characters in `weston-terminal`; pointer motion moves the client cursor.

### Phase 3 — xdg-shell window management
**Goal:** proper toplevels — title bars, move/resize/close, maximize.
- **Files:** front-end (`xdg_wm_base`/`xdg_surface`/`xdg_toplevel`).
- **Reuse:** wctl geometry + decorate, `_wsys_raise` (`:9566`), resize/close
  chrome + `"r"`/`"f"` events (§3), map-and-raise (`:7353`).
- **Risks:** configure/ack-configure handshake correctness; serial
  bookkeeping; popup/`xdg_positioner` (menus) fidelity.
- **Test:** `weston-terminal` resizes and reflows; close box works; a second
  toplevel stacks with correct z-order.

### Phase 4 — XWayland → X11 apps (free X11)
**Goal:** run a stock X11 app (`xterm`, `xeyes`) unmodified.
- **Files:** package/launch XWayland in the Linux ns; front-end must satisfy
  what XWayland uses (`wl_shm`, `wl_seat`, `xdg-shell`, and crucially real
  **SCM_RIGHTS** — Route B does not carry XWayland).
- **Reuse:** everything from Phases 1–3.
- **Risks:** XWayland is a demanding client (many fds, `wl_shm` pools,
  possibly `xwayland`-specific globals); rootful vs rootless; **hard
  dependency on Route A** SCM_RIGHTS.
- **Test:** `Xwayland :0 &` then `DISPLAY=:0 xeyes` renders inside a Hamnix
  window and tracks the pointer.

### Phase 5 — Firefox / Chromium
**Goal:** a real modern-web browser renders a page.
- **Files:** package the browser in the Linux ns; front-end hardening
  (multi-surface, subsurfaces, damage/frame-callback throughput, larger
  buffers).
- **Reuse:** all prior phases; **force software/shm rendering**
  (`MOZ_ENABLE_WAYLAND=1` + disable GPU/dmabuf; Chromium
  `--use-gl=swiftshader --disable-gpu` + `--ozone-platform=wayland`) so we
  never need `linux-dmabuf`.
- **Risks:** performance (per-frame full-window shm blits are heavy — need
  damage-tracking + `wl_surface.frame` throttling actually honoured);
  memory (browser buffers ≫ 4 MiB backbuffer cap — must lift
  `WSYS_BB_*` sizing or make it per-window dynamic); subsurfaces
  (video/compositing) may need multiple wids or a compositing step;
  `wl_shm` throughput through the byte-copy blit; sandbox/`clone` flags,
  `pidfd`, `io_uring`, `memfd` seals the browser expects.
- **Test:** launch the browser under XWayland *or* native Wayland; load a
  local static page; pixel-diff a known-good screenshot; then a real site
  over the existing net stack.

---

## 7. What could make this infeasible

1. **SCM_RIGHTS proves unworkable for a native receiver.** If resolving a
   passed fd to shareable physical pages cannot be made coherent with the
   client's writes (e.g. the client's memfd is not actually the same physical
   object the front-end maps), the whole zero/one-copy shm model collapses.
   *Assessment: LOW risk* — tmpfs MAP_SHARED coherence is already proven for
   `apt` pkgcache (`mm/vma.ad:3342-3355`), and memfd is anonymous tmpfs, so
   the same frames are reachable. This is the single biggest thing to
   de-risk in a Phase-0 spike (see §8).
2. **The v2 backbuffer cap / memory.** Browser windows want ≫1280×800 and
   many surfaces; the fixed `WSYS_BB_BYTES_PER_WIN=4 MiB` (`devwsys.ad:6361`)
   and 32-window cap force a resize/dynamic-alloc rework. *Medium risk;
   contained to devwsys.*
3. **linux-dmabuf / GPU buffers.** If a target client refuses software
   buffers and demands dmabuf/GPU sharing, we would need GPU buffer export
   across the ns — out of scope. *Mitigation: force shm/software rendering
   (§6 Phase 5). If Chromium/Firefox cannot be coerced off GPU on this
   platform, Phase 5 stalls.*
4. **Wayland client breadth of syscalls.** Real clients lean on `epoll`,
   `eventfd`, `signalfd`, `timerfd`, `clock_gettime`, `pidfd`, `memfd` seals,
   `clone` thread flags. Most exist (`u_epoll.ad`, `u_memfd.ad`, `u_pidfd.ad`
   present), but any missing one can wedge a client. *Medium risk;
   incremental — surface as ENOSYS during bring-up.*
5. **Single global focus / one seat.** `wsys_focus_wid` is a single global
   (`devwsys.ad:9100`); multi-seat or subsurface focus subtleties may not
   map. *Low risk for a single-user desktop.*
6. **Performance of the byte-copy blit.** Every commit is a
   format-converting memcpy (`_wsys_blit_store_rect` `:6620`). A 30fps
   1080p video surface is ~250 MB/s of conversion; may be too slow. *Medium
   risk; mitigate by honouring damage rects and frame callbacks.*

None of these is a *hard* architectural blocker for the Phase 1–4 target
(Wayland-native + X11 apps). Phase 5 browsers are gated on (2), (3-mitigated),
(4), and (6) — all engineering, not impossibility.

---

## 8. Recommended Phase-0 de-risking spike (before any Wayland code)

Prove the gate in isolation: a tiny Linux-ns C program `memfd_create`s a
page, `mmap`s it MAP_SHARED, writes a sentinel; a native Hamnix probe
resolves that backing object and maps its physical page; assert it reads the
sentinel and that a native write is seen by the Linux-ns side. If that round
trips, §7.1 is retired and Route A is confirmed buildable. This is the one
experiment that most cheaply converts the "feasible-but-blocked" verdict into
"green to build."

---

## 9. Native-Wayland Firefox bring-up (2026-07-04)

**UPDATE 2026-07-07 — XWayland X11 apps now RENDER (Phase 4 done).** The
earlier "render-blocked / shm-pixman paints black" verdict was wrong for the
*software* path: modern Xwayland only drives *glamor* through GL/EGL (hence
"GLX: no usable GL providers"), but the `Xwayland -shm` flag (mutually
exclusive with `-glamor`) selects a pure-pixman software screen that copies
into `wl_shm` buffers with **no GL at all** — no llvmpipe/Mesa needed. On the
native compositor `DISPLAY=:0 xsetroot -solid red` re-presents the full X
root: the compositor logs `shm buffer committed 800x600 … nonzero_px=480000`
and the screendump shows a solid-red "Xwayland on :0" window composited into a
Hamnix DE window. `xdpyinfo` reports display `:0` (11.0, 800x600, 1 screen).
The full ladder passes: (a) Xwayland↔compositor, (b) X display up, (c) X11 app
renders. Frame callbacks (`linux_abi/wayland.ad:1317`) drive the re-present, so
the "one commit then black" theory is retired. `xeyes` looks black only because
it is transparent/`ParentRelative` over the DEFAULT black X root (black-on-
black `nonzero_px=45`), not a pipeline gap — run `xsetroot` first and its
window shows on the red root. Test: `scripts/test_wayland_phase5_xwayland.sh`
(rung (c) = `xsetroot -solid red`; xeyes kept as a SIGALRM/storm probe).

**Known blocker at `-m 6G` (NOT XWayland/ABI):** verify XWayland at **`-m 3G`**.
At 6G the 2nd X-client exec dies with a kernel #PF that *halts* the box: the
faulting `memset` is in `mm/vma.ad::_vma_alloc_large` (`:3537`), zeroing a
freshly `alloc_pages`'d chunk **via its physical/identity VA**. When RAM > 4 GiB
that chunk sits above 4 GiB (e.g. cphys≈4.9 GiB); the running Linux-ABI *task's*
cr3 (whose low half is the user address space) does not identity-map that high
physical page, so the kernel-mode write faults (present under boot cr3 via a
1 GiB huge page, absent under the task cr3). This is a high-memory
identity-map gap (agent #69 page-allocator territory), independent of Wayland/
X — it will bite any large-RAM Hamnix workload. At ≤ 4 GiB no page exists above
4 GiB, so the path is safe and XWayland works end-to-end.

Per the earlier pivot, the real modern-browser path remains **Firefox as
a native Wayland client** via `MOZ_ENABLE_WAYLAND=1`, bypassing X entirely —
the same transport `weston-terminal` already renders over; XWayland now gives
the *legacy X11 app* path for free alongside it.

### 9.1 Fixture + image (DONE, verified)

- `scripts/stage_firefox.sh` stages the unmodified Debian `firefox-esr`
  (140.10.2esr) + its external GTK3 closure into the debian-minbase
  fixture. Layered on `stage_weston_term.sh` (shared cairo/pango/freetype/
  fontconfig/wayland base).
- Firefox is SELF-CONTAINED under `/usr/lib/firefox-esr` (~261 MiB;
  `libxul.so` alone 164 MiB; bundles NSS/sqlite/vpx/av-codec) — copied
  wholesale (not DT_NEEDED-discoverable). It does NOT bundle NSPR
  (`libnspr4/libplc4/libplds4`) — staged explicitly.
- dlopen'd modules the readelf walk misses are handled: gdk-pixbuf loaders
  (+ regenerated `loaders.cache`), gtk immodules, compiled GSettings
  `gschemas.compiled`, `shared-mime-info`.
- Full DT_NEEDED closure resolves (83 sonames; only optional
  `libcloudproviders.so.0` lazy-absent). Rootfs grows to ~406 MiB → build
  with `HAMNIX_ROOTFS_SIZE_MB=768`.
- **Verified in-image**: `HAMNIX_LIVE_MINIMAL=0` full-mirror build carries
  `/distro/usr/lib/firefox-esr/{firefox-esr,libxul.so}`, NSPR, GTK3, and
  the pixbuf `loaders.cache` (debugfs stat on `hamnix-live-distro.img`).

### 9.2 Launch harness

`scripts/test_wayland_firefox.sh` boots the full-mirror live image, waits
for the DE, and launches firefox-esr under the live session with
`MOZ_ENABLE_WAYLAND=1 GDK_BACKEND=wayland`, software render everywhere
(`LIBGL_ALWAYS_SOFTWARE=1 MOZ_ACCELERATED=0` + swgl WebRender forced in the
staged profile), sandbox disabled, fresh throwaway profile, `-no-remote
-new-instance about:blank`. Reports a 4-rung ladder: (a) Wayland registry
advertised, (b) main window maps (wl_shm commit), (c) chrome renders
(screendump non-flat), (d) about:blank loads.

### 9.3 Ladder reached so far — GATED at launch on memory/load

First boot + DE bringup succeed (RAM squashfs → 575 MiB RAM ext4 distro
extracted, `[live-root] DONE`, handoff, `[visual_gate] done`). At the
Firefox launch step the **guest dies with no clean fault dump** (serial log
ends mid-command; Firefox never reaches `execve`; screendump fails →
qemu gone). Two runs died at different points (6G: ~18 s into DE; 4G: at
the launch command), i.e. instability under load, not a deterministic
ABI ENOSYS.

Two contributing factors, both known:
1. **Memory pressure.** With `-m 4G` the guest only sees ~2.3 GiB total
   (the in-RAM 575 MiB distro ext4 + squashfs reserve a large slice), and
   ~1.3 GiB free when Firefox starts. libxul is 164 MiB mapped + Firefox's
   heap/threads on top — this is exactly the heavy-allocation regime where
   agent #69's page-allocator free-list `#GP`
   (`mm/page_alloc.ad::mm_page_alloc__alloc_pages_raw`) bites. NOT fixed
   here (owned by #69). Mitigation to retry: `QEMU_MEM=8G` in a quiet
   window so the guest has real headroom above the RAM-disk reservation.
2. **Host CPU starvation from concurrent TCG-QEMU** (see MEMORY
   "Verification under load"): other sessions' qemu runs starve the host
   and can crash a KVM guest's I/O spuriously. This run overlapped two
   concurrent net-test qemus. **Re-verify Firefox in a genuinely quiet
   host window** (single qemu) before drawing an ABI conclusion.

### 9.4 Next gates

- Re-run `scripts/test_wayland_firefox.sh` with `QEMU_MEM=8G` in a quiet
  host window; capture the first real Firefox serial line (ld.so error /
  GTK assert / registry bind / a `mm_page_alloc` `#GP`).
- If it is #69's page-allocator `#GP`: blocked on that fix; retry after.
- Once Firefox execs cleanly: expect the next gaps in the heavily-threaded
  startup (clone thread flags, futex, memfd seals, eventfd/timerfd/epoll
  edge cases, `getrandom`, dbus socket) — fix bounded ones in `linux_abi/`.
- Consider shrinking guest memory pressure structurally: the live distro
  need not hold the full 575 MiB in RAM if Firefox is demand-paged from the
  virtio image instead of the RAM ext4 (separate track).
