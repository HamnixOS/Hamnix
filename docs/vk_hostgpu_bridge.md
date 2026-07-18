# Host-GPU bridge: rendering the vk spine through real Linux Vulkan

GPU track / "Vulkan back into work on Linux". This bridge lets our native vk
graphics spine be verified against the **dev host's real Vulkan stack**
(NVIDIA / Mesa / lavapipe) so hambrowse, the DE, and games can be host-tested
with genuine hardware 3D acceleration — complementing the in-VM virtio-gpu path
(owned separately by the venus/virtio-gpu work).

## What's actually on this dev host (probed 2026-07-17)

| Capability | Status |
|---|---|
| `libvulkan.so.1` | present (loader 1.4.309) — **no** dev headers, **no** bare `.so`, **no** `vulkaninfo` |
| Real GPU | **NVIDIA GeForce RTX 3090**, driver 550.163.01, Vulkan 1.3.277 |
| SW Vulkan | **lavapipe / llvmpipe** (`libvulkan_lvp.so`, `lvp_icd.json`), Vulkan 1.4.305 |
| Other ICDs | intel, intel_hasvk, radeon, nouveau, virtio, gfxstream (installed, unused here) |
| SPIR-V toolchain (binary) | **absent** (no `glslc` / `glslangValidator` / `spirv-*`) |
| SPIR-V toolchain (**library**) | **present** — `libshaderc.so.1` (Debian `libshaderc1`); glslc's whole compiler as a shared object (no `-dev` headers) |
| QEMU GL | `virtio-gpu-gl-pci`, `virtio-vga-gl` available (that's the other agent's path) |

Consequences that shaped the design:
- **No Vulkan/shaderc headers** → the bridge hand-declares the minimal,
  ABI-stable subset it needs and links the versioned `.so` directly. Same
  pattern for both `libvulkan.so.1` and `libshaderc.so.1`.
- **The SPIR-V blocker is resolved by the *library*.** The `glslc` binary is
  not installed, but `libshaderc.so.1` is — so `scripts/shaderc_compile.c`
  hand-declares shaderc's tiny C API, links the `.so`, and compiles our GLSL to
  SPIR-V at gate time. This unlocked a **real compute pipeline** (below); the
  earlier "fixed-function transfer ops only" limitation no longer applies.

## Why a C bridge and a file seam (not a direct call from Adder)

The Adder `x86_64-linux` host target links a **static, no-libc, no-PIE** ELF
with raw `syscall` wrappers (see `compiler/adder.py`). It has no dynamic loader
and no libc, so an Adder host binary **cannot dlopen/link `libvulkan.so.1`**.

So the real GPU lives behind a tiny C-ABI bridge:

```
 lib/vk/vk_2d.ad  (native rasterizer, kernel + host dual-target)
        │  composites into an RGBA8888 vk color image
        ▼
 lib/vk/vk_hostgpu.ad  →  build/host/vk_hostgpu_ref  →  reference.ppm  ← SW reference
        │                                                    │
        │  (file seam: the composited framebuffer)           │
        ▼                                                     │
 scripts/vk_hostgpu_bridge.c  →  build/host/vk_hostgpu_bridge │
        │  uploads to a real VkDevice, runs a GPU transfer,   │
        │  reads back                                         ▼
        └────────────────────► gpu.ppm  ==(byte-identical)== reference.ppm
```

The byte-identical readback proves our composited framebuffer marshals
losslessly through real Linux Vulkan on the actual GPU.

## Components (all owned by this bridge)

- **`lib/vk/vk_hostgpu.ad`** — Adder host harness. Composites a deterministic
  "browser-ish" scene (opaque + alpha rects, a scaled blit, a line, a rounded
  rect) through the native vk 2D layer into a 96×64 RGBA8888 vk color image and
  dumps a PPM. That PPM is both the SW reference and the bridge input.
- **`scripts/vk_hostgpu_bridge.c`** — C bridge linking system `libvulkan.so.1`.
  Enumerates devices (prefers discrete GPU; honours `VK_ICD_FILENAMES` to force
  e.g. lavapipe), creates a `VkInstance`/`VkDevice`/queue/command pool, and:
  - `info` — print the selected device.
  - `clear W H 0xRRGGBBAA OUT.ppm` — real `vkCmdClearColorImage`, readback.
  - `upload IN.ppm OUT.ppm` — upload pixels to a device image, image→buffer
    copy, readback (an identity round-trip).
  - `blit IN.ppm SCALE OUT.ppm` — upload, then **`vkCmdBlitImage`** scales the
    frame by `SCALE` on the GPU (LINEAR filter; NEAREST if `VK_HOSTGPU_NEAREST`
    is set), readback. Prints `BLIT_MS` (isolated GPU blit time). Headless.
  - **`raster OUT.ppm`** — GPU-rasterize the reference scene through a real
    **compute pipeline** (`scripts/shaders/vk2d_raster.comp.spv`) over storage
    buffers, readback. Prints `RASTER_GPU_MS` / `RASTER_SW_MS` and asserts a
    `0`-mismatch against a C port of the vk_2d ops. See "GPU rasterization".
  - **`rasterbench W H`** — fill+alpha-blend workload at arbitrary resolution
    over a **device-local** (VRAM) storage buffer; prints
    `RASTERBENCH_GPU_MS` / `_SW_MS` / `_SPEEDUP` — the crossover number.
  - `present IN.ppm [SCALE] [FRAMES]` — create a real **`VkSurfaceKHR` +
    `VkSwapchainKHR`** (Xlib WSI) and, for `FRAMES` iterations, acquire a
    swapchain image, `vkCmdBlitImage` the frame onto it (GPU scale +
    RGBA→swapchain-BGRA format-convert), and `vkQueuePresentKHR` — an actual
    hambrowse frame **on screen** through Vulkan. Prints mean `PRESENT_MS`.
    Compiled in only when built `-DHAVE_XLIB -lX11`; needs a reachable
    `$DISPLAY`.
- **`scripts/shaders/vk2d_raster.comp`** (+ committed `.spv`) — the compute
  shader porting vk_2d's `fill_rect` / `fill_rect_alpha` / `blit` / `roundrect`
  / `draw_line` with **bit-identical integer math** (packed LE RGBA8888, `/255`
  source-over, integer isqrt AA corners, Bresenham line). Op-selected by push
  constant; dest is one `uint` per pixel matching the vk color image layout.
- **`scripts/shaderc_compile.c`** — GLSL→SPIR-V via hand-declared `libshaderc`
  ABI. This is how the "no SPIR-V toolchain" blocker was cleared.
- **`scripts/test_vk_hostgpu.sh`** — the gate (7 steps + step 6b). Renders the SW
  reference, builds the bridge (plus an optional Xlib present build), runs the
  real-GPU upload round-trip (assert byte-identical), a real-GPU clear (assert
  corner pixel), a lavapipe round-trip, a **GPU blit** (assert NEAREST is
  byte-exact vs a CPU nearest-upscale and LINEAR is within tolerance of a CPU
  bilinear reference; reports GPU ms), and a **best-effort windowed present**
  (only when libX11 + a reachable `$DISPLAY` exist; SKIP, not FAIL, headless).
  Gracefully SKIPs the GPU arms (reports INCONCLUSIVE, never false-greens) if
  libvulkan is absent, and still asserts the SW reference.

## Verified evidence (this host, 2026-07-17)

```
real GPU device: NVIDIA GeForce RTX 3090 [discrete-GPU]
PASS GPU readback BYTE-IDENTICAL to SW reference   (upload round-trip)
PASS GPU clear corner == #1122cc                   (vkCmdClearColorImage)
PASS lavapipe round-trip BYTE-IDENTICAL            (SW Vulkan marshalling)
PASS GPU blit NEAREST byte-exact + LINEAR ~= CPU bilinear (vkCmdBlitImage 3x)
     GPU blit time: nearest=0.153ms linear=0.121ms  (96x64 -> 288x192)
PASS presented 384x256 to a real window via NVIDIA RTX 3090 swapchain
     15.28 ms/frame  (FIFO / vsync-bound; the blit itself is sub-millisecond)
```

Blit is HW-independent: forced onto lavapipe (`VK_ICD_FILENAMES=lvp_icd.json`)
the scaled output is **byte-identical** to the RTX 3090 output — but at
**29.4 ms** vs the RTX's **0.15 ms** (a ~195x real-GPU speedup on the scale op).

`scripts/test_vk_2d_host.sh` still PASSes (no regression to the SW host render).

## GPU rasterization (the core win) — a real SPIR-V compute pipeline

The gap analysis found ~91% of a game frame (and much of a browser frame) is the
CPU software rasterizer's fill/blit inner loops. The bridge now runs those on
the GPU. `scripts/shaders/vk2d_raster.comp` ports the **exact integer math** of
`lib/vk/vk_2d.ad` — `fill_rect`, `fill_rect_alpha` (source-over `/255`), `blit`
(nearest, source-over), `fill_roundrect` (integer-isqrt AA corners), and
`draw_line` (Bresenham) — into a compute shader. Compute (not a graphics
pipeline) is deliberate: reproducing the SW rasterizer's arithmetic verbatim
makes the result **bit-identical**, which is the strongest proof of the port
(a graphics rasterizer's own coverage/rounding could diverge at edges).

**Toolchain:** the `glslc` binary is absent but `libshaderc.so.1` is installed;
`scripts/shaderc_compile.c` hand-declares its C ABI, links the `.so`, and
compiles the GLSL to 14 756 bytes of SPIR-V. The `.spv` is committed so the gate
runs even without libshaderc, but the gate regenerates it from source when the
library is present (proving the toolchain live).

```
GPU-raster of the 96x64 vk2d scene  ==(BYTE-IDENTICAL)== vk_2d.ad SW reference
     fill + alpha-blend + blit + rounded-rect + line, all pixel-exact on the RTX 3090

Crossover (fill + full-screen alpha-blend, device-local VRAM, best of N):
     res         GPU raster   SW raster   speedup
     96x64        0.088 ms     0.012 ms    0.14x   (overhead-bound: submit/fence dominates)
     640x480      0.10  ms     0.64  ms    6.2x
     1280x720     0.11  ms     1.87  ms    16.4x
     1920x1080    0.16  ms     4.28  ms    27.4x
     3840x2160    0.35  ms     18.1  ms    51x
```

GPU raster time is nearly **flat** with resolution (the fills are trivially
parallel; the RTX 3090 is overhead-bound until 4K), while the CPU cost scales
linearly with pixel count — exactly why the SW rasterizer dominates real frames
and the GPU erases it. At tiny sizes (a 96×64 icon) the GPU *loses* to submit
overhead; the win is at frame scale.

**Next step (on-device):** route `lib/vk/vk_2d.ad`'s actual rasterization
through this pipeline on the in-VM virtio-gpu/venus path. The op semantics are
already proven bit-identical, so the device path is a plumbing change: emit the
same push-constant op list from `vk_core`'s `VK_OP_2D_*` command-buffer records
into a virtio-gpu compute submission instead of the CPU inner loops, keeping the
SW path as the golden oracle. Batch all ops of a frame into one submit (as the
bench does) so per-frame overhead is amortized.

### Seeing hambrowse on the real GPU (a machine with a display)

```sh
gcc -O2 -DHAVE_XLIB scripts/vk_hostgpu_bridge.c -o vkx \
    /usr/lib/x86_64-linux-gnu/libvulkan.so.1 -lX11
python3 -m compiler.adder compile --target=x86_64-linux \
    lib/vk/vk_hostgpu.ad -o ref && ./ref frame.ppm      # composited framebuffer
DISPLAY=:0 ./vkx present frame.ppm 6 600                # 6x-scaled window, ~10s
```

A window titled "hambrowse via real Vulkan (RTX)" opens showing the composited
browser scene (chrome bar, content card, alpha panel, GPU-scaled icon, separator
line, rounded button), each frame blit-scaled and presented by the RTX 3090.

## Honest scope — what this is and isn't

- **Is:** a proven, real-hardware Vulkan path with a **live on-screen window**.
  Our composited framebuffer is uploaded to, GPU-scaled (`vkCmdBlitImage`) by,
  presented from (`VkSwapchainKHR` → `vkQueuePresentKHR`), and read back from the
  real RTX 3090 (and lavapipe) with bit-exact fidelity, plus a real GPU command
  (`clear`) producing correct pixels. The whole vk2d op set feeds it.
- **Isn't (yet):** the bridge does GPU **transfer / clear / blit / present**
  ops, not GPU **rasterization** — our triangle/fill rasterizer still runs on the
  CPU (in `vk_2d.ad`); the GPU validates the scale + present/marshalling path.
  This is the right rung: it needs no SPIR-V and (bar the window) works headless.

## Next steps to get hambrowse rendering through real Linux 3D

1. ~~**Present-to-window**~~ **DONE** — `present` creates a real `VkSurfaceKHR`
   (Xlib WSI) + `VkSwapchainKHR` and shows the frame in an on-screen window on
   the RTX 3090.
2. ~~**GPU blit/scale**~~ **DONE** — `vkCmdBlitImage` scales (and
   format-converts) the frame on the GPU, shader-free; used by both `blit` and
   `present`.
3. **GPU rasterization**: once a SPIR-V toolchain is available (install
   `glslang`/`shaderc`, or ship precompiled SPIR-V), move `vk_2d`'s fill/blit
   onto a real graphics pipeline — the venus/Zink-shaped path in the GPU-track
   design.
4. **Direct seam (no file)**: when a dynamic (libc-linked) Adder host target
   lands, call the bridge's C-ABI seam
   (`vk_hostgpu_init` / `vk_hostgpu_present_rgba` / `vk_hostgpu_shutdown`)
   directly from `vk2d_present()` instead of via a PPM file.

## Reusable harness

```sh
scripts/test_vk_hostgpu.sh                     # full 7-step gate (ref + GPU + present)
build/host/vk_hostgpu_bridge info              # enumerate + select real Vulkan device
build/host/vk_hostgpu_bridge blit f.ppm 3 o.ppm  # GPU vkCmdBlitImage 3x scale, timed
DISPLAY=:0 build/host/vk_hostgpu_bridge_x present f.ppm 6 600  # on-screen window
```
