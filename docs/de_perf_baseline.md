# DE compositor performance baseline (BEFORE Vulkan unification)

This is the standing **BEFORE** baseline for the DE compositor's CPU
rasterization / compositing throughput, recorded before the Vulkan-unification
work routes the DE through the vk spine (a later phase, "Phase C"). After the
vk backend lands, re-run the *exact same* harness on the *same quiet host* and
compare: the vk-routed DE should composite one frame **as fast or faster**, and
the per-primitive-class breakdown shows which primitives it changed.

## What is measured

The DE draws by building a text display list (`lib/hamscene.ad`) that the
kernel scene compositor (`sys/src/9/port/devwsys.ad`) rasterizes to `/dev/fb`.
`lib/hamui_host.ad` is the **dual-target twin** of that compositor: it parses
the same display list and rasterizes it to an RGB framebuffer on the dev host,
with no QEMU (see `docs/hamui_dual_target.md`). The bench times
`hamui_host_rasterize()` — the same per-primitive fill/glyph/image compositing
the kernel path performs (`_wsys_present_window` / `fb_present_rgba_row` and the
`_wsys_cache_*` primitives), byte-for-byte the same rounding and AA math.

- **Scene**: a representative MATE-style DE frame — full-screen wallpaper fill,
  a top panel (menu text + clock), a bottom taskbar with three window buttons,
  four desktop icon tiles with labels, three overlapping application windows
  (each with a rounded title bar + title text + up to eight body-text lines),
  and one 96×96 RGBA image blit (nearest-neighbor scaled, alpha-composited) in
  the middle window. **58 primitives** total. A rendered PNG of this exact frame
  can be dumped with `BENCH_DE_PPM=1` (build/host/bench_de_frame.png).
- **Resolution**: 1024×768 (RGB, 3 bytes/px). This is the host rasterizer's
  native framebuffer ceiling (`HOST_MAX_W`/`HOST_MAX_H` in `lib/hamui_host.ad`);
  it was chosen so the bench needs **no** change to DE code. A realistic desktop
  resolution; scale per-pixel numbers linearly for 1080p (~2.1×).
- **Iterations**: 100 timed iterations per scene (after 3 warmups), reporting
  **min** (best-of-N, the cleanest signal) and **mean**. Configurable via
  `BENCH_DE_ITERS`.
- **Clock**: `CLOCK_MONOTONIC` via the raw Linux `clock_gettime` syscall (228).
- **Per-frame**: each timed iteration is a full frame = framebuffer clear
  (`hamui_host_begin`) + `hamui_host_rasterize`. The embedded DejaVu TTF faces
  and the 8×16 VGA font are loaded once (guarded) before the timed loop, so the
  loop measures pure raster cost.

## How to reproduce

```
bash scripts/bench_de_compositor.sh
# or, for the rendered frame + more iterations:
BENCH_DE_PPM=1 BENCH_DE_ITERS=300 bash scripts/bench_de_compositor.sh
```

The `min_ms` value is the best-of-N frame time. The `CLEAR` row is the
framebuffer-clear cost alone; the `composite-only` rows subtract it so each
primitive class shows its net compositing cost.

## Baseline numbers

- **Host**: Intel Core i7-8086K @ 4.00 GHz (12 threads), single-threaded bench.
- **Measured**: 2026-07-17. Load average during measurement ~1.3–2.8 (the host
  had other agents running); numbers were **stable across 4 runs to <1.5%**, so
  the baseline is trustworthy, but see the caveat below — re-take on a fully
  quiet host if you want the tightest AFTER comparison.

| Scene   | min ms/frame | mean ms/frame | composite-only (min − CLEAR) |
|---------|-------------:|--------------:|-----------------------------:|
| CLEAR   |         4.41 |          4.58 |                            — |
| **FULL**|    **24.32** |     **25.15** |                    **19.91** |
| FILLS   |        21.78 |         22.52 |                        17.37 |
| GLYPHS  |         6.59 |          6.85 |                         2.11 |
| IMAGE   |         4.79 |          4.95 |                         0.34 |

**Headline: ~24.3 ms to composite one full representative DE frame** (1024×768,
58 primitives) on the CPU rasterizer — i.e. ~41 fps if a frame were re-composited
from scratch every time.

### Where the time goes

- **Fill rects dominate** (~17.4 ms composite, ~87% of the frame). The frame is
  overwhelmingly large opaque/alpha rectangle area — the full-screen wallpaper
  plus window bodies — painted one pixel at a time by the scalar `_put_px` /
  `_put_px_blend` inner loops. **This is exactly what a GPU/vk backend should
  collapse**: bulk rectangle fills and blits are the primitive class the vk
  spine changes most.
- **Framebuffer clear** is ~4.4 ms on its own — a byte-wise zero of the
  1024×768×3 buffer; a vk backend (or even a `memset`) should erase most of it.
- **AA TrueType glyphs** cost ~2.1 ms composite for all the window/panel text
  (per-glyph 4×4-supersampled coverage). Moderate; a glyph atlas on the GPU
  would cut it but it is not the bottleneck.
- **Image blit** is cheap here (~0.34 ms) because it is one small 96×96 source;
  it scales with image area, not frame area.

## Honesty note — does this host metric represent on-device DE compositing?

**Mostly yes for the primitive math, with two caveats.**

1. **Same rasterizer math, different clear/present accounting.** `hamui_host.ad`
   and the kernel `devwsys.ad` compositor share the same per-primitive fill /
   glyph-AA / image-blit code and rounding, so the *relative* per-class costs
   and the fills-dominate conclusion transfer directly. The host path, however,
   clears + rasterizes the *whole screen* every frame, whereas the device
   compositor keeps **per-window caches** and only recomposites damaged regions
   and does the final z-blit to `/dev/fb` (`_wsys_present_window`,
   `fb_present_rgba_row`). So the host FULL number is closer to a *worst-case
   full-screen redraw* than to a typical incremental device frame — real device
   frames that touch one window will be cheaper.
2. **Host CPU ≠ device CPU.** The absolute ms are on a 4 GHz desktop i7. On the
   ARM64 bring-up target (Pinebook Pro / RK3399) or under TCG the same code is
   materially slower. Compare BEFORE/AFTER on the **same** host, not across hosts.

**Recommendation:** this host bench is the right instrument for the vk
*rasterization/compositing* comparison — it isolates exactly the fill/glyph/blit
work the vk spine replaces, deterministically and in seconds. But for a *true*
end-to-end "is the DE faster on real hardware" claim, also do an **on-device
frame-timing pass** (instrument `_wsys_present_window` recompose→present with
`CLOCK_MONOTONIC` deltas on the shipped OVMF image) so the per-window-cache +
damage-clip + fb-present costs that the host path does not model are captured.
The host bench proves the *compositing kernel* got faster; the on-device pass
proves the *whole DE frame* got faster.
