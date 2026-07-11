# Making a hamUI GUI app dual-target (host render + native run)

A native Hamnix GUI app draws by writing a **scene display list** to
`/dev/wsys/<wid>/scene` and reads input from `/dev/wsys/<wid>/{keys,event}`.
Historically the only way to SEE an app render was a full installer-image
QEMU boot (~6 min), and the only way to test an interaction was to boot and
click. That is far too slow to iterate a GUI.

This document describes the **dual-target seam** that fixes it: any scene app
can be compiled + rendered on the developer's **host Linux** in milliseconds —
its scene rasterized to a PNG you can LOOK at, its input driven by a script —
while the **native** path (real scene to `/dev/wsys` via 9P) is unchanged. It
generalizes what the browser did with `lib/htmlengine.ad` +
`user/hambrowse_host.ad` to the whole hamUI toolkit.

Two apps already follow this pattern end to end and gate in Tier-1 CI:
`ham2048scene` and `hamcalcscene`.

## The seam (how it works)

```
        app CORE (pure)                 SINK (target-selected)
  ┌────────────────────────┐        ┌──────────────────────────────┐
  │ lib/<app>core.ad        │  build │ NATIVE  user/<app>scene.ad    │
  │  state machine          │──list─▶│   hamscene_commit(wid) ──9P──▶ /dev/wsys/<wid>/scene
  │  layout                 │  into  │                               │
  │  <app>_build_scene()    │  the   │ HOST    user/<app>scene_host.ad
  │  pure input handlers    │ shared │   hamui_host_rasterize() ────▶ RGB framebuffer ─▶ PPM ─▶ PNG
  └────────────────────────┘ buffer └──────────────────────────────┘
         │  imports only
         ▼
  lib/hamscene.ad  ── the PURE, extern-free scene builder (hamscene_fill/
                       rect/text/glyphs/glyphs_bold/line/stroke + panel/icon
                       helpers) writing one text display list into a module-
                       scope buffer. NO extern, imports nothing → links into
                       BOTH the x86_64-adder-user and x86_64-linux targets.
```

The scene display list is a small line-oriented text grammar (`fill x y w h
#rrggbb`, `glyphs x y "str" #rrggbb [b]`, `line`, `stroke`, …). The **native**
sink `hamscene_commit()` (still in `lib/hamui.ad`, Hamnix-only) writes that
buffer to `/dev/wsys/<wid>/scene`. The **host** sink `lib/hamui_host.ad`
parses the SAME buffer and rasterizes it into an RGB framebuffer using the
SAME 8x16 VGA font the compositor draws (`lib/hamui_host_font.ad`), so the PNG
shows what a native boot would.

### Why a core lib is required

The Adder compiler links **every transitively-imported module in full** (no
tree-shaking). `lib/hamui.ad` declares Hamnix-only externs (`sys_mmap`,
`sys_yield`, `sys_open_write`, …) that the host runtime (`user/linux-runtime.S`,
which only provides read/write/open/close/lseek/exit) cannot resolve. So the
host driver must NOT import `lib/hamui.ad`. The app's pure logic therefore
lives in an **extern-free core** that imports only `lib/hamscene.ad`.

## Recipe: make an app `foo` dual-target

1. **Factor a core** `lib/foocore.ad` — move the app's state machine, layout,
   the scene builder (renamed `foo_build_scene()`, WITHOUT the
   `hamscene_commit()` call), and the pure input handlers out of
   `user/fooscene.ad`. Rules:
   - `import` ONLY `from lib.hamscene import …` (the pure builder). No
     `extern`, no syscalls, no I/O.
   - Expose a clear PUBLIC API (no leading underscore) for everything the two
     drivers call: `foo_init` / `foo_reset`, `foo_layout`, `foo_build_scene`,
     the input entry points (`foo_key_line`, `foo_resize_line`,
     `foo_*_at`, `foo_press*`, `parse_pointer`), and a few state getters for
     assertions (`foo_score()`, `foo_acc()`, …).
   - Keep any tiny pure helpers the builder needs (`_slen`, `_u64_to_dec`) in
     the core and import them into the native driver — don't duplicate them
     (two public defs of the same name is a hard link error; two *private*
     `_name` defs in different modules are fine — they're module-scoped).

2. **Slim the native driver** `user/fooscene.ad` — keep ONLY the wsys
   transport (`_newwindow`, `_winpath`, the `/keys`+`/event` loop) and a thin
   `emit_scene(wid)` wrapper = `foo_build_scene(); hamscene_commit(wid)`.
   `from lib.hamui import hamscene_commit` and `from lib.foocore import …`.
   Behaviour must be byte-identical to before the split.

3. **Add a host driver** `user/fooscene_host.ad` — built for `x86_64-linux`:
   - Declare the host externs (`sys_open(path,flags,mode)`, `sys_write`,
     `sys_close`) — the Linux ABI, supplied by `user/linux-runtime.S`.
   - `from lib.hamui_host import hamui_host_begin, hamui_host_rasterize,
     hamui_host_ppm_header, hamui_host_fb_ptr, hamui_host_fb_bytes,
     hamui_host_pixel` and `from lib.foocore import …`.
   - Seed DETERMINISTICALLY (fixed seed, no clock) so the render is stable.
   - `foo_init(); foo_layout(); foo_reset()`, then `foo_build_scene();
     hamui_host_begin(w,h); hamui_host_rasterize()`, write a PPM
     (`_write_ppm`: `sys_open(path, 577, 420)` = `O_WRONLY|O_CREAT|O_TRUNC`,
     mode 0644; header from `hamui_host_ppm_header`, then `hamui_host_fb_ptr`
     for `hamui_host_fb_bytes`).
   - Drive SCRIPTED input through the core's pure handlers (build the wire
     lines the compositor delivers — keyboard `"d <code>"`, pointer
     `"m <x> <y> <buttons>"`), then re-render an "after" PPM.
   - Dump the raw scene (framed by `SCENE-BEGIN` / `SCENE-END`), a few sampled
     pixels (`hamui_host_pixel`), and state getters to stdout for machine
     assertions. No sockets, no Plan 9 — it only reads argv + writes files.

4. **Add a gate** `scripts/test_foo_host.sh` (copy an existing one):
   - Compile the host driver `--target=x86_64-linux` and the native app
     `--target=x86_64-adder-user` (the no-regress check).
   - Run the host driver, convert the PPMs to PNG with
     `scripts/ppm_to_png.py` (Python stdlib zlib only — no image tools).
   - Assert on the scene grammar (widget geometry / text / colours), on a few
     rasterized pixels (proves the rasterizer, not just the builder), and that
     scripted input changed state.

5. **Wire it into Tier-1 CI** — add the gate to the `host-selftests` job's
   "hamUI GUI apps" step in `.github/workflows/ci.yml` (deterministic,
   milliseconds, no QEMU).

6. **Confirm the native render once.** The host gate proves logic + layout +
   the display list; boot the installer image once to confirm the compositor
   still blits the real scene (kill only your own `$QEMU_PID`). After that,
   iterate on the host.

## Rasterizer support & limits (`lib/hamui_host.ad`)

- Verbs drawn: `fill`/`rect` (solid), `stroke` (4-edge outline), `line`
  (Bresenham, square brush for thickness), `text`/`glyphs`/`glyphs_bold`
  (8x16 VGA font; `b` flag double-strikes). Colours `#rgb`/`#rrggbb`/
  `#rrggbbaa` (alpha currently ignored — opaque draw).
- `text` is rendered top-left like `glyphs` (native anchors it at the
  baseline); fine for eyeballing. Most scene apps use `glyphs`.
- Framebuffer BSS ceiling 1024x768; `hamui_host_begin` clamps + clears.
- The font table is generated from `drivers/video/console/fb_font_8x16.S`
  by `scripts/gen_hamui_host_font.py` — regenerate if that font changes.

## Files

| File | Role |
|------|------|
| `lib/hamscene.ad` | PURE scene display-list builder (the seam) |
| `lib/hamui.ad` | native toolkit; keeps `hamscene_commit` (9P sink), re-exports the builders |
| `lib/hamui_host.ad` | HOST rasterizer sink (scene → RGB framebuffer → PPM) |
| `lib/hamui_host_font.ad` | 8x16 VGA font table (generated) |
| `lib/ham2048core.ad`, `lib/hamcalccore.ad` | example app cores |
| `user/ham2048scene.ad`, `user/hamcalcscene.ad` | native drivers (transport only) |
| `user/ham2048scene_host.ad`, `user/hamcalcscene_host.ad` | host drivers |
| `scripts/test_ham2048_host.sh`, `scripts/test_hamcalc_host.sh` | Tier-1 gates |
| `scripts/ppm_to_png.py` | stdlib-only PPM→PNG converter |

## Apps ready to be dual-targeted next

Same recipe applies (each is a scene app on `hamscene_*`): `hamfmscene`
(file manager), `hameditscene` (text editor), `hammonscene` (system monitor),
`hamtermscene` (terminal), `hampanelscene` (the MATE-style panel/launcher),
and `hamdesktop` (icons + wallpaper). `hamfm` has an existing
`lib/hamfmcore.ad` to build on. Start with the most self-contained /
deterministic (hammon, hamedit) before the stateful ones.
