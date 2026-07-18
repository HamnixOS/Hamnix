# hambrowse's real page rendering on the RTX 3090

This wires hambrowse's **own paint output for an actual web page** through the
proven host-GPU bridge so the browser's rendering executes on the discrete GPU
(RTX 3090), byte-verified against a CPU oracle and nvidia-smi-proven.

Prior art (`scripts/vk_hostgpu_bridge.c pageraster`) rasterized a *hand-authored*
representative DE+browser frame on the GPU. This closes the loop: the frame now
comes from the **live web engine layout of a real HTML fixture**, not an author's
mock-up.

## Pipeline

```
  tests/fixtures/hambrowse_fidelity.html
        │  he_layout() + htmlpaint  (user/hambrowse_host_gfx.ad)
        ▼
  PAGEOPS 888 1126                 ← real laid-out paint records, dumped as a
  OP fill  0 0 888 1126 #ffffffff     stable, GPU-ingestible op stream
  OP rrect ... / OP fill ...          (block backgrounds, image boxes)
  OP line  150 645 265 645 1 #808080ff (every table-cell / border stroke)
  OP covmask 150 300 470 24 #101010ff 11280  (text run — real AA coverage → GPU)
  <11280 hex bytes: 8-bit per-pixel coverage over the tight ink bbox>
  ENDOPS
        │  scripts/vk_hostgpu_bridge.c  pagefromops OPS.txt OUT.ppm [SECONDS]
        ▼
  RTX 3090 Vulkan compute pipeline (scripts/shaders/vk2d_raster.comp.spv)
        │  readback + byte-verify vs CPU oracle running the IDENTICAL op stream
        ▼
  OUT.ppm  (MISMATCH 0)  +  nvidia-smi per-process residency proof
```

### Op-dump (`user/hambrowse_host_gfx.ad`)

Passing the `dumpops` token makes the driver emit a `PAGEOPS…ENDOPS` block after
paint. Every op is derived from the live engine layout via the existing query
API — nothing is hand-authored:

| Source (real layout)                     | Op emitted            | Target |
|------------------------------------------|-----------------------|--------|
| page background                          | `OP fill` (white)     | GPU    |
| block background fills (`he_bfill_*`)    | `OP fill` / `OP rrect`| GPU    |
| image boxes (`he_seg_img>=0`)            | `OP fill` (sampled)   | GPU    |
| bordered boxes (`htmlpage_border_*`)     | `OP line` ×4 edges    | GPU    |
| text runs (segments)                     | `OP covmask`          | GPU    |

Colors are real: backgrounds/text use `he_bfill_rgb`/`he_seg_rgb`; borders use
the actually-painted top-edge pixel. Text runs are emitted **last** (topmost
paint order). The 32-bit RGBA op colors (`#rrggbbaa`) are distinct from the
24-bit `_o_hexcol` proof lines the existing gates parse, so those gates are
unaffected (op lines only appear with `dumpops`).

#### OP_COV_MASK — real anti-aliased text on the GPU

A text run's true per-pixel AA coverage is the exact bitmap `font_ttf`'s
rasterizer produced. To recover it the driver **re-renders each run's glyphs**
(via the same `htmlpaint_text_ttf` the page painter uses — same face/size
mapping, baseline and faux-oblique shear) into a scratch RGBA target painted
**black-on-white**: `_blend_px` writes `255-cov` per channel, so
`coverage = 255 - red` — the rasterizer's coverage, exactly, with the internal
page framebuffer untouched (target redirection only swaps a pointer). The
coverage is trimmed to its ink bounding box and emitted as:

```
OP covmask x y w h #rrggbbaa <nbytes>
<nbytes*2 hex chars — one 8-bit coverage per pixel, row-major, wrapped 64 B/line>
```

The colour alpha is `ff` (opaque); the **mask carries the per-pixel alpha**. The
bridge reads the `nbytes` hex bytes after the header (whitespace-skipping), packs
every run's coverage end-to-end into the `src[]` SSBO (one value per uint), and
dispatches `OP_COVMASK` on the compute shader: for each pixel it reads
`cov = src[mask_off + (Y-py)*w + (X-px)]` and blends `colour` by `a*cov/255`
(src-over) — the **identical** integer math the CPU oracle runs, so the GPU
readback is byte-for-byte the oracle image.

### Ingestion (`scripts/vk_hostgpu_bridge.c` → `mode_pagefromops`)

Parses the op stream, maps it onto the same `vk_2d` op vocabulary
(`OP_FILL`/`OP_FILL_ALPHA`/`OP_ROUNDRECT`/`OP_LINE`/`OP_COVMASK`) that `pageraster`
uses, and:

1. Records **every op — boxes AND text coverage masks** — onto the RTX 3090
   compute pipeline, one dispatch per op with barriers, in file order (text last
   ⇒ topmost), in a timed submit loop; reads the SSBO back.
2. Runs a **CPU oracle** over the identical op stream and byte-verifies the two
   images (RGB): `PAGEFROMOPS_GPUvsCPUport_MISMATCH` must be 0.

Every GPU shader op — including `OP_COVMASK` — is a bit-exact integer twin of the
CPU op, so the whole page (backgrounds, borders **and text**) matches to the byte.

## Text runs now on the GPU (was: honest CPU fallback)

Text is no longer a CPU fallback: the `OP_COV_MASK` op (above) uploads each run's
**true per-glyph AA coverage** and blends it in the compute shader, so real
anti-aliased glyphs composite on the RTX 3090. The report:

```
PAGEFROMOPS_OK ... ops=82 gpu_ops=82 glyph_cpu_ops=0 text_gpu_ops=40 gpu_frames=1899 order_grouped=1
PAGEFROMOPS_GPUvsCPUport_MISMATCH 0
```

All **82 ops** (page/element backgrounds, rounded rects, every table-cell/border
stroke, and all **40 text runs** as coverage masks) rasterized on the RTX 3090;
`glyph_cpu_ops=0`. The legacy flat `OP glyph` box path is still parsed (routed to
`OP_FILL_ALPHA`) for backward compatibility, but the driver emits `OP covmask`.

## Verification

`scripts/test_hambrowse_gpu_render.sh` (in `ci_battery_manifest.txt`):

- compiles the driver (frozen Adder seed), renders the fixture, dumps ops;
- GPU-rasterizes via `pagefromops` for 3s so **nvidia-smi** observes the bridge
  pid resident on the GPU;
- asserts `MISMATCH 0`, a **discrete-NVIDIA** device was selected, `gpu_ops>0`,
  and **all text runs moved to the GPU** (`text_gpu_ops>0`, `glyph_cpu_ops==0`);
- regression-checks that the proven `pageraster` path still byte-matches;
- **SKIPs cleanly (exit 0)** when the Adder compiler, libvulkan, gcc, the shader
  SPIR-V, or a real (non-llvmpipe) Vulkan device is absent.

Measured on the RTX 3090 (host-visible SSBO): GPU ~1.28 ms vs CPU ~1.41 ms per
888×1126 frame (~1.1×; small op counts on a PCIe-mapped buffer — the win grows
with op count/resolution, cf. `rasterbench`). The result is the browser's real
page paint — backgrounds, borders **and anti-aliased text** — executing on the
discrete GPU, byte-identical to the CPU oracle.

## What remains toward full live DE/browser-on-GPU

- **Real image texels** — image boxes are currently reduced to a sampled solid
  color; a real `blit` of decoded image pixels (the bridge already has the blit
  op) would render photos on the GPU.
- **In-guest transport** — this runs the op dump host-side; the live path is the
  Hamnix DE writing the same op stream to `/dev/wsys/<wid>/scene` and the native
  Vulkan driver consuming it on-silicon (GPU track #181-185).
