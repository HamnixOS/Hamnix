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
| SPIR-V toolchain | **absent** (no `glslc` / `glslangValidator`) |
| QEMU GL | `virtio-gpu-gl-pci`, `virtio-vga-gl` available (that's the other agent's path) |

Consequences that shaped the design:
- **No SPIR-V compiler** → the bridge uses only fixed-function transfer ops
  (`vkCmdClearColorImage`, buffer↔image copy). No shaders required.
- **No Vulkan headers** → the bridge hand-declares the minimal, ABI-stable
  subset it needs and links the versioned `libvulkan.so.1` directly.

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
  - `present IN.ppm [SCALE] [FRAMES]` — create a real **`VkSurfaceKHR` +
    `VkSwapchainKHR`** (Xlib WSI) and, for `FRAMES` iterations, acquire a
    swapchain image, `vkCmdBlitImage` the frame onto it (GPU scale +
    RGBA→swapchain-BGRA format-convert), and `vkQueuePresentKHR` — an actual
    hambrowse frame **on screen** through Vulkan. Prints mean `PRESENT_MS`.
    Compiled in only when built `-DHAVE_XLIB -lX11`; needs a reachable
    `$DISPLAY`.
- **`scripts/test_vk_hostgpu.sh`** — the gate (7 steps). Renders the SW
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
