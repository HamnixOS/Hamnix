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

## AFTER — Phase C: DE host rasterizer routed through the vk 2D spine

Phase C landed: `lib/hamui_host.ad` no longer owns a private software
rasterizer. Every primitive now paints through the vk 2D primitive layer
(`lib/vk/vk_2d.ad` — the exact ops the kernel vk command buffer replays at
`vkQueueSubmit`) into a vk-style **RGBA8888** colour image
(`VK_FORMAT_R8G8B8A8_UNORM`), which is flattened (RGBA → RGB) into a present
buffer for the PPM writer. Mapping: `_fill_rect`→`vk2d_raster_fill_rect`,
`_fill_rect_a`→`vk2d_raster_fill_rect_alpha`, `_host_blit_image`→
`vk2d_raster_blit`, `_fill_roundrect`→`vk2d_raster_fill_roundrect`, glyph blits
→`vk2d_raster_cov_mask` (font rasterizes each glyph to a coverage bitmap; the op
stamps it), `_draw_line`→`vk2d_raster_draw_line`. The public `hamui_host_*` /
hamscene API and all DE app code are unchanged.

**Byte-identical pixels: PROVEN.** The representative bench frame
(`BENCH_DE_PPM=1`, 58 primitives, 1024×768) is `cmp` byte-for-byte identical
before vs after the reroute, and all six QEMU-free DE host gates
(`test_shotoverlay_host`, `test_de_panel_clock_host`, `test_hamctl_host`,
`test_hamctl_resize_host`, `test_hamctl_wallpaper_host`, `test_de_icon_wrap_host`)
still PASS — including their per-pixel probes (headerbar gradient, MATE-blue
selection row, dark-glyph-pixel counts, scrim-see-through). vk_2d's integer
source-over/coverage math is identical to the old `_put_px_blend`, so the colour
image's RGB channels evolve exactly as the old RGB framebuffer did (the
write-only alpha byte is dropped at flatten).

### AFTER numbers (same host, i7-8086K @ 4 GHz; load ~0.8–1.3; 200 iters, 3 runs, min-ms variance <0.4%)

| Scene   | BEFORE min ms | AFTER min ms | composite-only BEFORE → AFTER |
|---------|--------------:|-------------:|------------------------------:|
| CLEAR   |          4.41 |     **9.57** |                           — |
| **FULL**|     **24.29** |    **32.74** |         **19.88 → 23.18**   |
| FILLS   |         21.72 |        29.59 |             17.31 → 20.02   |
| GLYPHS  |          6.56 |        12.23 |              2.15 →  2.65   |
| IMAGE   |          4.80 |        10.00 |              0.39 →  0.42   |

**Result: a small–moderate REGRESSION on the CPU replay path, exactly as
expected — NOT a speedup.** This is the honest outcome: vk2d's fills run the
*same* software fill math as the old `hamui_host` inner loops, so no algorithmic
speedup was possible on the CPU. Where the overhead comes from:

1. **RGBA (4 bytes/px) vs the old RGB (3 bytes/px) colour target.** The vk image
   is `VK_FORMAT_R8G8B8A8_UNORM`, so every pixel write moves 33% more bytes and
   the frame carries a 4th channel. This is the dominant cost on the
   fill-dominated frame (fills composite-only +2.7 ms, +16%).
2. **Per-pixel clip bounds-checks in the shared vk2d store/blend.** The biggest
   single jump is CLEAR (4.41 → 9.57 ms): the old `hamui_host_begin` cleared with
   a tight `hostfb[i]=0` byte loop, whereas the clear now routes through
   `vk2d_raster_fill_rect` → per-pixel `_vk2d_store` with four clip branches and
   four byte stores per pixel. The composite-only classes (fills/glyphs/image)
   grow only ~16% / ~23% / ~8%; the flatten pass (RGBA→RGB) is outside the timed
   `hamui_host_rasterize`/`hamui_host_begin` loop.

**This transitional CPU overhead is the price of becoming a vk client, and it is
exactly what a GPU backend behind the same vk2d API (Phase D) erases:** a
render-pass load-op clear (or `vkCmdClearColorImage`) collapses the CLEAR cost,
and bulk rectangle fills / blits / a glyph atlas move off the scalar CPU path
entirely — with the vk2d call sites and the byte-exact golden pixels unchanged.
The value delivered here is architectural (the DE is now one vk client sharing
the hamSDL/hamGame spine from Phase B), not a CPU-speed win.

## AFTER (optimized) — vk2d CPU inner-loop optimization

The Phase-C reroute overhead was *not* inherent to becoming a vk client — it
was the `vk_2d.ad` inner loops doing a per-pixel clipped, byte-at-a-time store
where the old private rasterizers could not (they shared the same scalar shape).
Optimizing **only** `lib/vk/vk_2d.ad` (no call-site or format change; output
proven byte-identical) recovers the whole regression **and** beats the original
pre-vk baseline:

1. **Clip hoisted to per-primitive.** Every `fill_rect` / `fill_rect_alpha` /
   `blit` / `cov_mask` (glyph) / `roundrect` clamps its rectangle to the image
   bounds **once**, so the inner pixel loop has **no** per-pixel bounds branch
   (was four compare-branches per pixel). This is the single biggest win — it
   is what more-than-doubled CLEAR in the regression.
2. **Opaque packed-word fast path.** A fully-opaque fill (the whole-screen
   CLEAR, wallpaper, window bodies, opaque `fill_rect_alpha`) now writes one
   packed little-endian RGBA `uint32` per pixel (`r|g<<8|b<<16|0xFF<<24`)
   instead of four byte stores — byte-identical bytes, ~4× fewer stores. The
   CLEAR is now a tight packed-word row fill of the whole image.
3. **Hoisted-constant translucent blend.** The source-over fill lifts the
   constant `src*a` terms out of the inner loop (only the dest load varies) and
   drops the per-pixel function call.

### AFTER-optimized numbers (same host, i7-8086K @ 4 GHz; load ~1.0–1.3; 100 iters, 3 runs, min-ms variance <0.5%)

| Scene   | ORIG baseline (RGB) | Phase-C REGRESSED (RGBA) | **AFTER-optimized (RGBA)** |
|---------|--------------------:|-------------------------:|---------------------------:|
| CLEAR   |                4.41 |                     9.57 |                   **1.76** |
| **FULL**|           **24.32** |                **32.74** |                  **9.14**  |
| FILLS   |               21.78 |                    29.59 |                   **6.32** |
| GLYPHS  |                6.59 |                    12.23 |                   **4.16** |
| IMAGE   |                4.79 |                    10.00 |                   **2.15** |
| full composite-only | 19.91       |                    23.18 |                   **7.37** |

**Result: the ~8.4 ms Phase-C regression is FULLY recovered — and then some.**
FULL went 32.74 → **9.14 ms**, i.e. the entire +8.4 ms regression plus ~15 ms
*below* the original 24.32 ms pre-vk baseline (a 3.6× speedup vs the regressed
path, 2.7× vs the original private rasterizer). CLEAR (4.41→9.57→**1.76**) shows
the packed-word whole-image fill; FILLS (21.78→29.59→**6.32**) the hoisted clip
+ opaque word store. Pixels are **byte-identical**: the representative 58-prim
bench frame (`BENCH_DE_PPM=1`) `cmp`s equal before vs after, the vk2d 64×64
render `cmp`s equal, and all five DE host gates + the seven game/hamSDL host
gates (`test_vk_2d_host`, `test_ham2048_host`, `test_hamsnake_host`,
`test_hamchess_host`, `test_hamsdl_host`, `test_hamgame_host`,
`test_hamsh_pygame_host`) PASS unchanged. Because vk2d is the shared spine, the
same win lands on every hamSDL game for free.

**Residual gap (the RGBA-format cost only a GPU erases).** The color target is
still `VK_FORMAT_R8G8B8A8_UNORM` (4 bytes/px vs the old RGB 3 bytes/px) — that
is the vk image contract and is unchanged here. The optimization neutralizes it
on the *opaque* path (a packed 32-bit store moves 4 bytes in one instruction,
so 4-vs-3-byte no longer costs) but the *translucent* blend and glyph paths
still touch the 4th channel; that irreducible ~fraction, plus the RGBA→RGB
flatten (outside the timed loop), is the sliver a GPU backend (Phase D:
`vkCmdClearColorImage` / render-pass load-op + bulk fills off the scalar CPU)
removes entirely. But on the CPU path the regression is gone.

### Kernel compositor (`sys/src/9/port/devwsys.ad`) — deferred to Phase C.2

Only the **host** compositor was rerouted this round (it is what the bench +
before/after comparison measure). The kernel `devwsys.ad` twin routing is the
deeper Phase C.2 follow-up: device-side text needs a **glyph atlas** to feed the
coverage-mask op (the kernel has no host font rasterizer in the compositor path),
so it is a larger change kept separate to hold this round byte-clean.

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

## Phase D — on-device present-path measurement (virtio-gpu scanout offload)

Measured on-device under OVMF with a GOP linear framebuffer + a native
virtio-gpu device present simultaneously (`-device virtio-vga`, which exposes
BOTH the OVMF GOP linear FB and the virtio-1.0 GPU control device), full
**1280×800** scanout frame, best-of-5, `tsc_monotonic_ns()` timing. Driven by
`vk_gpu_present_benchmark()` (lib/vk/vk_selftest.ad), gated on the boot:37.vgpu
self-test. `[vgpu-bench]` serial markers.

| Present path | best-of-5 | vs SW |
|---|---|---|
| **SW GOP present** — `fb_present_rgba_row` per-pixel repack + MMIO STORE, ~1.02M px | **11.77 ms** | 1.00× |
| **GPU present** — `vk_gpu_present_image`: CPU RGBA→BGRA convert copy **+** TRANSFER_TO_HOST_2D + RESOURCE_FLUSH | **11.28 ms** | **1.04×** |
| **GPU present, device-only** — pure TRANSFER_TO_HOST_2D + RESOURCE_FLUSH (backing already BGRA, no CPU copy) | **0.19 ms** | **61×** |

**Correctness:** the GPU-presented BGRA backing matches the SW RGBA source frame
pixel-for-pixel (`_vgpu_bench_verify`, full-frame compare, 0 mismatches).

### What this proves — and the honest fill story

* **The present/scanout offload is real and large (≈61×)** — but only when the
  frame is already in the device's BGRA backing, so present is a pure device
  DMA (`TRANSFER_TO_HOST_2D`) + composite (`RESOURCE_FLUSH`) with no CPU work.
  The SW path's cost is ~1M uncached GOP-MMIO stores; the device path replaces
  all of them with one bulk DMA + one flush.
* **With the RGBA→BGRA convert copy included, the win collapses to ~4%**: the
  convert copy (cacheable RAM, ~1M px) costs about the same as the SW per-pixel
  MMIO present it replaces. So `vk_gpu_present_image` (convert-then-present) is
  the *wrong* shape to capture the win. **The next optimization is to render the
  vk color image / DE composite directly into a BGRA backing** so present drops
  the convert and becomes the 61× device-only path. That is a clean follow-up on
  the SAME seam (no new device work).
* **Fills stay CPU-bound on base virtio-gpu-2d.** virtio-gpu 2D is a *scanout*
  device: it presents a host resource but does NOT rasterize into it — the CPU
  still draws every fill/line/blit/glyph into the backing. `vk_gpu_clear`/
  `vk_gpu_fill_rect` are CPU loops over the backing, not device blits. Real
  fill/compute acceleration requires **venus/virgl 3D** (GL/Vulkan command
  passthrough to the host GPU) — a separate, larger GPU track (#182 venus), NOT
  attempted here.

### Decision (this round)

Default stays **SW** (`vk_set_backend` seam unchanged; `vk_try_enable_gpu_present`
added as the DE/compositor opt-in). The convert-included GPU present is only ~4%
faster, so flipping the default is **not** justified yet. The recommended next
step is the BGRA-native present (drop the convert → 61× present) followed by
venus/virgl for actual fill/compute acceleration.
