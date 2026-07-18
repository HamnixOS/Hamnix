# Gamelang gap analysis — Adder + hamSDL vs C++ + SDL2 vs Python + pygame

_2026-07-17. A rigorous, honesty-first comparison of the three ways to write a
2D game against the Hamnix stack. This is a **research deliverable, not a
win-claim**: it reports the tools that were actually available on the bench host
and labels every fallback._

Sources (own dir `tests/bench/gamelang/`):
`bounce_game.ad` (shared sim + draw, target-agnostic), `bounce_hamsdl_host.ad`
(host driver, real timing), `bounce_hamsdl_dev.ad` (native device driver,
dual-target proof), `bounce_cpp.cpp`, `bounce_pygame.py`,
`bench_gamelang.sh` (timing), `check_gamelang.sh` (correctness gate).

## The benchmark

The 2D-game essential loop: **N axis-aligned sprites**, each an 8×8 filled rect
with an integer position and velocity, **updated + bounced off the window walls
every frame and drawn**, for **M frames**, into a 640×480 window. A `uint64`
checksum of the final sprite state is the cross-language invariant.

- **Apples-to-apples.** The simulation is **integer-only** (an LCG seeds the
  sprites; positions/velocities are ints), so it is bit-exact across the three
  languages. All three print the **identical checksum** — `check_gamelang.sh`
  recomputes the golden value for any `(N,M)` and asserts every arm matches
  before any timing is trusted. Verified golden at N=500,M=2000:
  `ca68e03653271261`.
- **What is measured.** Per-frame cost = `(best-of-R at M frames − best-of-R at
  M=0 startup baseline) / M`. Subtracting the M=0 run removes process startup and
  sprite seeding, isolating the frame loop (update + draw + present). Reps
  best-of-4+, same host CPU, back-to-back.
- **N=500** because hamSDL's display list is a 16 KB text buffer (`lib/hamscene.ad`,
  `HAMSCENE_CAP=16384`), which holds ~630 rect primitives; 500 leaves headroom.
  This is within the task's 500–2000 sprite range.

## Tool availability on the bench host (honesty caveats)

| Tool | Present? | Consequence |
|------|----------|-------------|
| `g++` / `gcc` | **yes** | C++ arm builds. |
| **libsdl2-dev** (`pkg-config sdl2`, `/usr/include/SDL2/SDL.h`) | **NO** | A direct **C++ + SDL2** program **cannot be compiled here.** The C++ arm is therefore a **pure software-blit** implementation (hand-rolled framebuffer writes, no SDL) — the honest "hand-written C++ SW rasterizer" baseline, **not** a measurement of SDL2's GPU renderer. |
| **pygame** (`import pygame`) | **yes** — pygame 2.6.1 / **SDL 2.28.4** | The pygame arm is a **real pygame program driving real SDL2 2.28.** It runs under the SDL `dummy` video driver (headless), so `screen.fill` + `pygame.draw.rect` still perform SDL2's **CPU software** surface blit — the only genuine SDL2 code path available here — but **not** SDL2's GPU-accelerated render-to-texture path. |
| Python | 3.11.10 (CPython) | pygame arm host. |

**Bottom line on tooling:** there is no GPU-accelerated SDL2 measurement on this
host. The pygame number is SDL2's *software* path; a real accelerated SDL2/pygame
game would be **faster** than the pygame number shown. Read the numbers with that
ceiling in mind.

## Measured numbers (this host CPU)

N=500 sprites, M=3000 frames, best-of-4, M=0 baseline subtracted:

| arm | ms/frame | ×C++ SW | GPU-accel? | code LOC | dependency footprint |
|-----|---------:|--------:|:----------:|---------:|----------------------|
| **Adder + hamSDL** (SW raster via vk2d) | **1.86** | 59.8× | no (SW) | 164¹ | **none** — Adder compiler + in-tree hamSDL lib; native ELF, no libc/runtime |
| **C++ SW-blit** `-O2` (no SDL2 on host) | **0.031** | 1.0× | no (SW) | 86 | libc only |
| **Python + pygame** (SDL2 2.28, SW/dummy) | **0.62** | 20.0× | no (SW here²) | 75 | CPython ~30 MB + pygame wheel bundling SDL2/image/ttf/mixer ~10 MB |

¹ shared sim `bounce_game.ad` (94) + host driver (70). ~35 of the driver lines are
hand-rolled `stdout`/`itoa`/`atoi` helpers that C's `printf`/`atoi` and Python's
`print` supply for free — see *Expressiveness* below. The native device driver
(`bounce_hamsdl_dev.ad`, 24 LOC) is a separate deliverable proving the same game
compiles for `x86_64-adder-user`.
² pygame *can* use GPU surfaces; this headless run measured its SW path.

### Where hamSDL's 1.86 ms actually goes

Splitting the frame with the harness's `PRESENT=0` knob (build + update the
display list, but skip the rasterize/present step):

| phase | ms/frame | share |
|-------|---------:|------:|
| display-list **build** (pure Adder: `sdl_begin_frame` + 501 `fill_rect`) | 0.157 | **8.6 %** |
| software **raster/present** (vk2d fills 640×480 + 500 sprites per frame) | 1.676 | **91.4 %** |

**This is the single most important finding: 91 % of hamSDL's per-frame cost is
the software rasterizer, not the language.** The Adder-built display list costs
~0.31 µs/primitive — cheap. The gap is entirely in the pixel-pushing.

## Analysis

### 1. Raw speed — the real gap is the rasterizer and the GPU, not the language

The Adder *language* is already competitive: prior standing bench
(`scripts/bench_adder_host.sh`, `docs/bench_adder_host.md`) puts Adder compute at
~1.6–1.8× of gcc-`-O2`, and here the Adder display-list build is only 8.6 % of
the frame. So the 59.8× vs the C++ SW baseline is **not** an Adder-vs-C compute
gap — it is the cost of hamSDL's **general-purpose software rasterizer** (the
vk2d path in `lib/hamsdl_vk.ad` → `lib/vk/vk_2d.ad`) versus a hand-written loop of
raw byte stores:

- The C++ arm writes opaque bytes straight into a framebuffer (`memset`-class
  stores the compiler vectorizes) → ~0.09 ns/pixel.
- hamSDL's raster is a **coverage + alpha-blend** rasterizer that also handles
  rounded rects and glyph coverage, replayed from a re-parsed text display list
  each frame → ~5.5 ns/pixel. General and correct, but ~60× the raw-store cost.
- pygame/SDL2's SW blitter sits in between (~20× the raw baseline, **3× faster
  than hamSDL**) because SDL2 has years of hand-tuned, SIMD-assisted blit
  routines and skips a text-display-list round-trip.

The deeper gap is **GPU acceleration**. SDL2's *default* renderer uploads to GPU
textures and composites on the GPU; neither the pygame-SW number here nor hamSDL
touch the GPU. A real accelerated SDL2 game would leave all three SW numbers
behind. hamSDL is SW-raster on both targets today (vk2d on host; the wsys
compositor on device). **The language is fine; the renderer is the frontier.**

### 2. Expressiveness / ergonomics — LOC and lines-to-first-pixel

- **Python + pygame (75 LOC)** is the most concise: dynamic typing, list
  comprehensions, `print`, and `pygame.draw.rect`/`display.flip` in ~4 lines to
  first pixel. Fastest to prototype; smallest source.
- **C++ SW-blit (86 LOC)** is middling: explicit types and a hand-written
  `fill_rect`, but `printf`/`atoi`/`malloc` from libc keep boilerplate down. A
  real SDL2 version would be ~6–8 lines to first pixel (`SDL_Init`,
  `CreateWindow`, `CreateRenderer`, `SetRenderDrawColor`, `RenderFillRect`,
  `RenderPresent`).
- **Adder + hamSDL (164 LOC across two files)** carries the most source, but the
  gap is **not the game logic** — the sim+draw core (`bounce_game.ad`) is a
  clean, readable ~94 lines with an SDL-flavored API (`sdl_begin_frame`,
  `sdl_fill_rect`, `sdl_clear`, `sdl_rgb`) that reads almost exactly like the
  pygame body. The overhead is the **host driver's ~35 lines of hand-rolled
  `stdout`/integer-to-hex/`atoi`** — because the freestanding Adder user target
  has no libc `printf`/`atoi`. Lines-to-first-pixel for a hamSDL *game* is on par
  with pygame (`sdl_dev_init` → `sdl_begin_frame` → `sdl_fill_rect` →
  `sdl_dev_present`, ~4 calls). Adder's static typing costs a few characters per
  line vs Python but buys the native-speed compute and memory-safety options.

**Ergonomic takeaway:** the hamSDL *drawing* surface is already pygame-class in
brevity. The tax is I/O plumbing in freestanding programs — a stdlib gap, not a
language-expressiveness gap.

### 3. Feature coverage — what hamSDL lacks vs SDL2 / pygame

hamSDL's round-1 public API (`lib/hamsdl.ad`) covers: color packing, `fill_rect`
/ `draw_rect` / `fill_round_rect` / `draw_line` / `blit` (pre-registered
surface) / cell text + bold + int; a unified event queue (keyboard, mouse
motion/button, window resize, quit); and fps/frame-delay timing. Two backends —
device (wsys window + `/event`+`/keys`) and host (render-to-PPM). That is a
complete *drawing + input + timing* surface. Gaps vs SDL2/pygame:

| capability | SDL2 / pygame | hamSDL | note |
|------------|:-------------:|:------:|------|
| GPU-accelerated renderer / hardware textures | yes | **no** | SW raster only (vk2d / wsys). #1 perf gap. |
| Audio mixer / sound playback | SDL_mixer / `pygame.mixer` | **no** | Hamnix has audio via separate DE scene apps (`user/hamaudioscene*`), not the hamSDL API. |
| Image file loading (PNG/JPG decode) | SDL_image / `pygame.image.load` | **no** | `blit` needs a pre-registered RGBA surface; PNG/JPEG decoders exist elsewhere in-tree but aren't wired into the hamSDL surface. |
| TrueType / proportional text | SDL_ttf / `pygame.font` | **no** | Text is fixed 8 px cell glyphs; `lib/font_ttf.ad` exists but isn't exposed through hamSDL's text API. |
| Texture rotation / scaling / blend modes | yes | partial | `blit` is axis-aligned; no rotation, limited blend. |
| Input breadth: wheel, key-repeat, mod-state query, text input/IME, clipboard, gamepad/joystick, relative-mouse | yes | **no** | Event set is keydown/up, motion, button, resize, quit only. |
| Multiple windows / fullscreen / display-mode enum / vsync | yes | **no** | Single wsys window; host has a scripted clock (no real delay/vsync). |
| Threading, timers, gamepad haptics, etc. | yes | **no** | Out of round-1 scope. |

### 4. Recommendation — where to invest to close the gaps

1. **GPU-accelerate the hamSDL present (highest leverage).** 91 % of the frame is
   software raster and the whole gap vs SDL2 is GPU. Route `sdl_host_present` /
   the device present through the **native Vulkan spine (GPU track #181–185)** so
   `fill_rect`/`blit`/`clear` become GPU ops instead of vk2d's SW coverage
   rasterizer. This closes both the 3× gap to pygame-SW and the larger gap to
   accelerated SDL2 in one move, and the public hamSDL API doesn't change.
2. **Add an audio API to the hamSDL surface** (an `sdl_mixer`-equivalent:
   load/play/stop/volume) so games don't reach around to the DE scene apps — the
   most-noticed missing pillar vs pygame/SDL2.
3. **Wire image loading + TTF text into hamSDL** — expose the in-tree PNG/JPEG
   decoders as `sdl_load_image` → registered surface, and `lib/font_ttf.ad` as a
   proportional `sdl_draw_text_ttf`. Removes two hard blockers for real games.
4. **Broaden the input event set** — mouse wheel, key-repeat + modifier state,
   text-input, and eventually gamepad — cheap additions to the existing queue.

The language layer is **not** where to spend: Adder compute is already ~1.6–1.8×
of C and the display-list build is 8.6 % of the frame. Invest in the **renderer
and the missing media/input pillars**, not the compiler.

## Reproduce

```
# correctness gate (fast, no timing, self-checks the golden checksum):
bash tests/bench/gamelang/check_gamelang.sh

# timing table (best-of-N, M=0 baseline subtracted):
bash tests/bench/gamelang/bench_gamelang.sh 500 3000 4

# build/raster split for hamSDL (PRESENT=0 skips the rasterizer):
build/host/bounce_hamsdl_host 500 3000 0   # build+update only
build/host/bounce_hamsdl_host 500 3000 1   # + software raster/present
```

`check_gamelang.sh` is deterministic and QEMU-free; it is ready to register as a
one-line CI gate (`ci_battery_manifest.txt`). The timing bench is a manual perf
fixture (wall-clock, not gate-appropriate).
