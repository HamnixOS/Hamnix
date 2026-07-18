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
  OP glyph 180 300 496 10 #......a0     (text runs — CPU fallback)
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
| text runs (segments)                     | `OP glyph`            | CPU    |

Colors are real: backgrounds/text use `he_bfill_rgb`/`he_seg_rgb`; borders use
the actually-painted top-edge pixel. Text runs are emitted **last** (topmost
paint order). The 32-bit RGBA op colors (`#rrggbbaa`) are distinct from the
24-bit `_o_hexcol` proof lines the existing gates parse, so those gates are
unaffected (op lines only appear with `dumpops`).

### Ingestion (`scripts/vk_hostgpu_bridge.c` → `mode_pagefromops`)

Parses the op stream, maps it onto the same `vk_2d` op vocabulary
(`OP_FILL`/`OP_FILL_ALPHA`/`OP_ROUNDRECT`/`OP_LINE`) that `pageraster` uses, and:

1. Records the **GPU-capable box ops** onto the RTX 3090 compute pipeline, one
   dispatch per op with barriers, in a timed submit loop; reads the SSBO back.
2. Applies the **`glyph` (text) ops on the CPU** over the GPU result, in file
   order (they were emitted last ⇒ topmost). See fallback note below.
3. Runs a **CPU oracle** over the identical op stream and byte-verifies the two
   images (RGB): `PAGEFROMOPS_GPUvsCPUport_MISMATCH` must be 0.

The GPU shader ops are bit-exact integer twins of the CPU ops, so the box paint
matches to the byte; the glyph ops are the same CPU code in both paths.

## Honest fallback: text runs

Text runs are the one thing the bridge cannot yet do on the GPU: **true
per-glyph anti-aliased coverage is not a GPU op** in this vocabulary. They are:

- emitted as `OP glyph` = the run's measured ink extent, at ~63% alpha to
  approximate average glyph density (a coverage box, **not** real glyph shapes);
- rasterized on the **CPU** (`glyph_cpu_ops` in the report), never faked as GPU.

The report prints the split explicitly, e.g. for the fidelity article:

```
PAGEFROMOPS_OK ... ops=80 gpu_ops=42 glyph_cpu_ops=38 gpu_frames=2231 order_grouped=1
PAGEFROMOPS_GPUvsCPUport_MISMATCH 0
```

So **42 box ops** (page/element backgrounds, rounded rects, and every one of the
40 table-cell/border strokes) rasterized on the RTX 3090; **38 text runs** fell
back to CPU. A future `OP_COV_MASK` glyph op (upload per-glyph AA coverage masks
and blend them in the compute shader) would move text onto the GPU too.

## Verification

`scripts/test_hambrowse_gpu_render.sh` (in `ci_battery_manifest.txt`):

- compiles the driver (frozen Adder seed), renders the fixture, dumps ops;
- GPU-rasterizes via `pagefromops` for 3s so **nvidia-smi** observes the bridge
  pid resident on the GPU;
- asserts `MISMATCH 0`, a **discrete-NVIDIA** device was selected, and `gpu_ops>0`;
- regression-checks that the proven `pageraster` path still byte-matches;
- **SKIPs cleanly (exit 0)** when the Adder compiler, libvulkan, gcc, the shader
  SPIR-V, or a real (non-llvmpipe) Vulkan device is absent.

Measured on the RTX 3090 (host-visible SSBO): GPU ~1.10 ms vs CPU ~1.23 ms per
888×1126 frame (~1.1×; small op counts on a PCIe-mapped buffer — the win grows
with op count/resolution, cf. `rasterbench`). The result is the browser's real
box paint executing on the discrete GPU, byte-identical to the CPU oracle.

## What remains toward full live DE/browser-on-GPU

- **GPU glyphs** — an `OP_COV_MASK` op (per-glyph AA coverage upload + blend in
  the shader) to move the 38 text ops off the CPU.
- **Real image texels** — image boxes are currently reduced to a sampled solid
  color; a real `blit` of decoded image pixels (the bridge already has the blit
  op) would render photos on the GPU.
- **In-guest transport** — this runs the op dump host-side; the live path is the
  Hamnix DE writing the same op stream to `/dev/wsys/<wid>/scene` and the native
  Vulkan driver consuming it on-silicon (GPU track #181-185).
