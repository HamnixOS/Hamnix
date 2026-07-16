# hamGame — a pygame-shaped game library for Hamnix

`lib/hamgame.ad` is the **pygame-shaped** game-creation layer for Hamnix. It is
to `lib/hamsdl.ad` what CPython's `pygame` is to C SDL: a friendly *object*
layer (Surface / Sprite / Rect / Clock) built **on top of** the SDL-flavored
core, not a reimplementation of it.

```
  user/<yourgame>.ad          user/<yourgame>_host.ad     <- thin drivers
  lib/<yourgame>.ad  (shared, target-agnostic game logic)
  ─────────────────────────────────────────────────────────────
  lib/hamgame.ad   Surface / Sprite / Rect / Clock / present   (pygame layer)
  lib/hamsdl.ad    colours / events / timing / scene draw verbs (SDL core)
  lib/hamscene.ad  display-list verbs   lib/hamui_host.ad  host rasterizer
  lib/png.ad       PNG decode           (DE scene/#128 named-image blit)
```

Everything is **dual-target** and `extern`-free in the core: `lib/hamgame.ad`
compiles for BOTH `x86_64-adder-user` (device) and `x86_64-linux` (host), so a
game iterates on the dev host with **no QEMU** and ships to the desktop
unchanged. Two thin present backends handle the transport, mirroring the hamSDL
split:

| file | target | role |
|------|--------|------|
| `lib/hamgame.ad`      | both | Surface/Sprite/Rect/Clock + pixel math + present-scene emission |
| `lib/hamgame_dev.ad`  | device | wsys window (reuses hamSDL), upload the display Surface + commit, jiffy clock, `/dev/audio` hook |
| `lib/hamgame_host.ad` | host | register the display Surface with the host sink + rasterize to a PPM, scripted clock |

## The present model (how a Surface reaches the screen on both targets)

pygame draws onto a **display Surface** (a real RGBA pixel buffer) and calls
`flip()`. hamGame does the same: all pixel drawing lands on the display Surface,
then the backend registers that buffer under a fixed name (`game_screen_name()`
== `"hg_screen"`) and hamGame emits **one** `image` scene verb referencing it —
`lib/hamscene.ad`'s named-image blit (the #128 path). The compositor (device) /
`lib/hamui_host.ad` (host) alpha-composites the same bytes, so **the PNG you look
at on the host is the frame a native boot renders**. Crisp HUD text is emitted
*after* as scene `glyphs` verbs (reusing the DE font engine), giving pixel
sprites **and** antialiased text in one frame.

Per-frame loop (see `user/hamgamedemo.ad`):

```
gd_render()                       # draw sprites onto the display Surface
game_flip_scene(display)          # begin scene + emit the display-image blit
game_draw_text_bold(...)          # optional HUD glyphs, drawn on top
game_dev_present(display)         # device: upload bytes + commit   (host: game_host_present)
game_dev_delay(game_frame_ms())   # pace to the target FPS
```

## API surface

### Colours (0xRRGGBBAA, shared with hamSDL)
- `game_rgb(r,g,b) -> uint32`, `game_rgba(r,g,b,a) -> uint32`

### Lifecycle
- `game_reset()` — free every Surface + Sprite and rewind the pixel arena
  (cheap per-level / per-test reset).

### Surface (pygame.Surface — an owned RGBA8888 buffer)
- `game_surface_new(w,h) -> int32` (handle; pixels start transparent)
- `game_display_new(w,h) -> int32` (allocate + mark as the screen)
- `game_surface_w/h(s) -> int32`, `game_surface_ptr(s) -> Ptr[uint8]`
- `game_surface_fill(s,color)`, `game_surface_fill_rect(s,x,y,w,h,color)`
- `game_surface_draw_rect(s,x,y,w,h,color)` (1px outline)
- `game_surface_draw_line(s,x1,y1,x2,y2,color)` (Bresenham)
- `game_surface_draw_circle(s,cx,cy,r,color)` (filled disc)
- `game_surface_set_pixel(s,x,y,color)`, `game_surface_get_pixel(s,x,y) -> uint32`
- `game_surface_set_colorkey(s,color)` / `game_surface_clear_colorkey(s)`
- `game_surface_blit(dst,src,dx,dy)` — full blit (per-pixel alpha + colourkey)
- `game_surface_blit_rect(dst,src,dx,dy,sx,sy,sw,sh)` — spritesheet sub-rect blit
- `game_load_png(buf,n) -> int32` — decode a PNG (reuses `lib/png.ad`) into a new Surface

Surfaces bump-allocate out of one 512 KiB BSS arena (`GAME_ARENA_BYTES`), up to
`GAME_SURF_MAX` (16) live at once.

### Sprite (pygame.sprite.Sprite)
- `game_sprite_new(surf,x,y) -> int32`
- `game_sprite_set_sheet(sp,sx,sy,sw,sh)` — source sub-rect within `surf` (spritesheet frame)
- `game_sprite_set_pos(sp,x,y)`, `game_sprite_move(sp,dx,dy)`
- `game_sprite_x/y/w/h(sp) -> int32`
- `game_sprite_draw(sp,dst)` — blit the (sub)surface onto `dst` at the sprite's pos
- `game_sprite_collide(a,b) -> int32` — AABB overlap of two sprites

### Rect (pygame.Rect)
- `game_rect_contains(rx,ry,rw,rh,px,py) -> int32` (collidepoint)
- `game_rect_collide(ax,ay,aw,ah,bx,by,bw,bh) -> int32` (colliderect / AABB)

### Frame present
- `game_screen_name() -> Ptr[uint8]` — the fixed display-image name
- `game_flip_scene(surf)` — begin the frame's scene + emit the display-image blit
- `game_draw_text(x,y,s,color)` / `game_draw_text_bold(...)` / `game_draw_int(x,y,v,color)` — HUD overlay
- backend present: `game_dev_present(surf)` (device) / `game_host_present(surf) -> int32` (host)

### Events (pygame.event, over the shared hamSDL queue)
- Kinds: `GAME_QUIT GAME_KEYDOWN GAME_KEYUP GAME_MOUSEMOTION GAME_MOUSEDOWN GAME_MOUSEUP GAME_RESIZE`
- Keys: `GAMEK_UP GAMEK_DOWN GAMEK_LEFT GAMEK_RIGHT` (printable keys = their ASCII byte)
- `game_poll_event(&kind,&key,&x,&y,&button) -> int32`
- `game_push_event(...)`, `game_push_quit()`
- `game_feed_keys_buffer(buf,n)` / `game_feed_event_buffer(buf,n)` — feed raw DE
  `/keys` + `/event` wire lines (arrow escape sequences, pointer clicks) through
  the shared parser; used by host tests to script input deterministically.

### Clock / timing (pygame.time.Clock)
- `game_set_fps(fps)`, `game_frame_ms() -> int32`, `game_frame_delay(elapsed_ms) -> int32`
- `game_clock_tick(now_ms) -> uint64` — delta-time in ms since the previous tick.
  The backend supplies `now_ms` (device: `game_dev_ticks()`; host:
  `game_host_ticks()` after `game_host_advance(ms)`). The **first** tick returns
  0 (no baseline); call it once to prime the clock.

### Audio (thin hook this round)
- `game_dev_play_pcm(buf,n) -> int32` (device) — stream already-decoded PCM
  bytes straight to the native HDA sink (`/dev/audio`, the same file `aplay`
  writes). No `ioctl`s, no sockets. A richer mixer (channels, looping, format
  negotiation via `/dev/audioctl`, host stub parity) is **deferred**.

## Reused vs new

**Reused, not reimplemented:** colours / events / timing / scene draw verbs
(`lib/hamsdl.ad`); the named-image blit + host image registry
(`lib/hamscene.ad` + `lib/hamui_host.ad`); the AA/scalable font engine (via the
scene `glyphs` verb); PNG decode (`lib/png.ad`); the device window/pump/commit
lifecycle (`lib/hamsdl_dev.ad`). **New:** the Surface/Sprite/Rect pixel math
(fill/line/circle/blit/colourkey/alpha compositing), the pygame object model +
handle pools, the display-backbuffer present, the delta-time Clock, and the
larger device upload buffer a full backbuffer needs (hamSDL's caps at 96×96).

## Demo + gate

`lib/hamgamedemo.ad` is "Coin Dash" (the pygame twin of `lib/sdlpong.ad`): a
2-frame animated avatar spritesheet you steer with the arrow keys to collect
coins (AABB pickup → score → coin relocates). It drives the device app
`user/hamgamedemo.ad` and the host harness `user/hamgamedemo_host.ad` through
the **same** public API.

`scripts/test_hamgame_host.sh` is the fast, QEMU-free gate: it compiles both
targets, renders `build/host/hamgame_{before,after}.png`, and asserts the
backbuffer rasterized (sampled pixel colours + a non-blank pixel count), that
arrow/raw input moves the sprite, that delta-time advances the animation frame,
and that AABB collision scores a pickup.
