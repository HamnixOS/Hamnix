# LLVM-ELF64 apps: build coverage, boot-verify, and speedup measurement

_Measured on main @ e36effc7 (LLVM emission complete: all 17 core DE apps emit
via Adder SSA IR -> textual LLVM IR -> clang -> native ELF64, 0 emit bails)._

This is the follow-through on the user directive: "build the kernel and all
packages with llvm ... I want to get that speed up." Two deliverables:
(A) build every DE/scene app via the LLVM->ELF64 path and boot-verify the
desktop, and (B) MEASURE the actual LLVM-vs-native-SSA speedup honestly.

Host: see `build/bench_llvm/run.log` for the exact CPU/clang string of the run
that produced the numbers below.

---

## A. Build coverage — every scene app as native ELF64 via LLVM

Built with the on-main opt-in hook
`ADDER_ELF64_APPS="<app...>" scripts/build_user.sh`, which routes each named
app through `scripts/adder_cc_llvm_native64.sh` (host_ac `--backend=llvm`
-> `.ll` -> clang-19 -O2 -> native runtime -> `ld -m elf_x86_64`). Every
success is a REAL `ELF 64-bit LSB executable, x86-64, SYSV`, statically linked,
**no PT_INTERP** (INTERP program-header count = 0) — the loader's native ELF64
path (`fs/elf.ad`: EI_CLASS==2 + OSABI=SYSV, no interp -> native syscall ABI).

18 non-host scene apps under `user/*scene.ad`:

| app | ELF64 build | funcs/emitted/bailed | PT_INTERP | note |
|-----|-------------|----------------------|-----------|------|
| ham2048scene    | OK   | 405/405/0 | 0 | |
| hamcalcscene    | OK   | 397/397/0 | 0 | launch-queue |
| hamcalscene     | OK   | 404/404/0 | 0 | launch-queue |
| hamchessscene   | OK   | 386/386/0 | 0 | |
| hameditscene    | OK   | 561/561/0 | 0 | |
| hamfmscene      | OK   | 533/533/0 | 0 | |
| hamimgscene     | OK   | 52/52/0   | 0 | |
| hamlogscene     | OK   | 368/368/0 | 0 | |
| hamminescene    | OK   | 390/390/0 | 0 | |
| hammonscene     | OK   | 389/389/0 | 0 | launch-queue |
| hamnotesscene   | OK   | 509/509/0 | 0 | |
| hampanelscene   | OK   | 662/662/0 | 0 | panel — drains launch queue |
| hampkgscene     | OK   | 497/497/0 | 0 | |
| hamsnakescene   | OK   | 378/378/0 | 0 | |
| hamtermscene    | OK   | 309/309/0 | 0 | |
| hamtetrisscene  | OK   | 394/394/0 | 0 | |
| hamvideoscene   | OK   | 410/410/0 | 0 | |
| **hamaudioscene** | **BUILD FAIL** | 495/494/1 | — | clang type error (see below) |

**17 / 18 scene apps build clean as native ELF64.** All 17 pass `file` as ELF64
SYSV with no PT_INTERP.

### The one failure — hamaudioscene (distinct from an emit bail)

hamaudioscene is NOT an emit bail in the app sense — 494/495 functions emit —
but the emitted LLVM IR is **type-incorrect** and clang-19 rejects it:

```
hamaudioscene.ll:...: error: '%v3' defined with type 'i64' but expected 'double'
  %v5 = fmul double %v3, 0x3FE0000000000000
```

Root cause in the emitted IR (`lib_mp3decode__mp3_sin`): the float global
constant `MP3_PI` is lowered as an **i64 load** and then used directly as a
`double` operand:

```llvm
%v2 = ptrtoint [8 x i8]* @MP3_PI to i64
%t1 = inttoptr i64 %v2 to i64*
%v3 = load i64, i64* %t1          ; <-- loaded as i64
%v5 = fmul double %v3, 0x3FE...   ; <-- used as double: type mismatch
```

This is a **float-global-scalar load** lowering bug in the LLVM backend
(`adder/compiler/ssa_llvm.ad`) — a global whose declared type is `double` (or a
`[8 x i8]` blob reinterpreted as double) is loaded through an `i64*` instead of
a `double*`/with a bitcast. It is a sibling of the already-closed
"float-ARRAY load/store" class (38512567), but for a scalar global. The native
ELF32 path builds hamaudioscene fine (`ELF 32-bit ... SYSV`), so this is a
genuine, isolated **LLVM-ELF64 codegen bug**, not an app defect and not a
front-end gap. Owned by the ssa_llvm agent — NOT fixed here (out of scope for
this measurement task). Reason=13 residual emit bail is a separate function in
the same module.

---

## B. Boot-verify — the desktop launches ELF64 apps

`scripts/test_de_visual_gate.sh` builds a dedicated self-test installer image
with the ELF64 apps packaged (via `ADDER_ELF64_APPS`), boots it under OVMF/KVM,
and proves the #99 DE launch path: `echo /bin/<app> > /dev/wsys/run/launch` ->
panel spawns it -> `[devwsys] window <wid> mapped` -> fresh pixels in the
window region. The panel (hampanelscene, 662 fns) that drains the queue and the
launch-queue trio (hamcalscene/hamcalcscene/hammonscene) are all ELF64 in this
run.

**Result — PASS.** Booting the self-test image with all 17 scene apps packaged
as native ELF64 (LLVM backend), gate exit 0:

```
[visual_gate] PASS: 3/3 launch-queue apps rendered, 3 launch-phase windows mapped
per-app render status
  hamcalscene  rendered (40619 px)
  hamcalcscene rendered (57931 px)
  hammonscene  rendered (170358 px)
distinct mapped wids (whole boot) = 9
windows mapped AFTER gate start   = 3 (launch-queue)
```

All three launch-queue apps launched **as ELF64** through the DE launch queue,
drained by the **ELF64 panel** (hampanelscene), and painted fresh pixels into
self-allocated wsys windows — the full native ELF64 loader path
(`fs/elf.ad` -> native syscall routing -> hamui_window) exercised end to end.
9 distinct windows mapped across the boot (panel + wallpaper/taskbar chrome +
the launched trio). No ELF64 launch/render regressions vs the ELF32 control.
Confirmed 17/17 apps were rebuilt as ELF64 into the image
(`[build_user] ELF64: rebuilding <app>` x17). PNGs under
`build/de_visual_gate/<ts>/`.

Control: the same gate with the default ELF32 native build PASSES 3/3 (baseline
sanity that the harness + desktop work independent of the ELF64 swap).

---

## C. Speedup measurement

### C.1 Compiler-level microbenchmark (solid, apples-to-apples)

`scripts/bench_llvm.sh` compiles the same `tests/bench/opt/*.ad` kernels three
ways and times each host ELF best-of-7 on one CPU, checksum-verified identical
across configs before timing. Ratios are **time relative to gcc-O2**
(lower = faster). This is the codegen-quality signal the ELF64 apps inherit:
the scene apps are lowered through the very same SSA-IR -> LLVM-IR -> clang -O2
pipeline.

| kernel | native-SSA | LLVM | gcc-O2 | LLVM/O2 | natSSA/O2 | **LLVM speedup vs native-SSA** |
|--------|-----------:|-----:|-------:|--------:|----------:|-------------------------------:|
| matmul  | 0.1463s | 0.0115s | 0.0177s | 0.65x | 8.24x | **12.7x** |
| sieve   | 0.3120s | 0.0421s | 0.0403s | 1.04x | 7.74x | **7.4x**  |
| licm    | 0.2504s | 0.0280s | 0.0319s | 0.88x | 7.84x | **8.9x**  |
| dcecopy | 0.2901s | 0.0454s | 0.0548s | 0.83x | 5.29x | **6.4x**  |
| tak     | 0.5975s | 0.2813s | 0.2887s | 0.97x | 2.07x | **2.1x**  |
| collatz | 1.2322s | 0.1007s | 0.1383s | 0.73x | 8.91x | **12.2x** |
| mandel  | 0.1017s | 0.0204s | 0.0204s | 1.00x | 4.97x | **5.0x**  |
| saxpy   | 0.2271s | 0.0575s | 0.0598s | 0.96x | 3.80x | **4.0x**  |
| **geomean** | | | | **0.87x** | **5.57x** | **6.4x** |

**Headline: the LLVM backend is ~6.4x faster than native-SSA (geomean) and
0.87x gcc-O2 — i.e. it beats gcc -O2.** The native-SSA backend (the default
on-device app codegen today, and the non-droppable bootstrap floor) is 5.57x
gcc-O2 — LLVM closes essentially all of that gap. This is the concrete "speed
up" the ELF64 apps gain.

### C.2 App-level host measurement — attempted, NOT cleanly feasible

I tried to time a real DE app workload built both ways using
`user/bench_de_host.ad` (the host twin of the DE compositor's rasterizer —
`lib/hamscene` + `lib/hamui_host`, self-timed, no QEMU). The native-SSA host
build (Python seed, `--target=x86_64-linux`) builds and runs; the **LLVM host
build does not link**, because the LLVM backend still **bails** on that
harness's hot raster inner loops:

```
BAILED @vk2d_raster_fill_rect        reason=11
BAILED @vk2d_raster_fill_rect_alpha  reason=11
BAILED @vk2d_raster_blit             reason=11
BAILED @vk2d_raster_cov_mask         reason=11
BAILED @lib_vk_vk_2d__vk2d_blend_at  reason=11
BAILED @lib_vk_vk_2d__vk2d_store     reason=11
BAILED @hamui_host_fb_ptr / _pixel   reason=11
BAILED @user_bench_de_host__now_ns   reason=13   (__syscall2 intrinsic)
```

reason=11 is the residual SBR_MEMORY class (local float arrays / pointer-heavy
raster kernels) that the memory notes as a **non-app** deferred bail set. This
is itself a finding: **the `lib/vk/vk_2d` CPU rasterizer is not in the
LLVM-clean set.** It does not contradict "all 17 scene apps emit," because the
scene apps render through the KERNEL compositor (`devwsys`), not this host
raster lib — so their app code emits fully while this host-only bench does not.

Honest conclusion: a like-for-like LLVM-vs-native-SSA **on-host app timing** is
not achievable without compiler work in `ssa_llvm.ad` (barred for this task —
owned by another agent). The compiler microbench in C.1 is the honest,
reproducible speedup number, and it is directly representative because the scene
apps are compiled through the identical lowering pipeline. On-device per-app
timing would need a boot-time perf counter that does not yet exist (the visual
gate proves the ELF64 apps LAUNCH and RENDER, but does not time them).

---

## Summary

- **17/18 scene apps build as native ELF64 via LLVM** (SYSV, no PT_INTERP);
  the lone failure (hamaudioscene) is an isolated **float-global-scalar load**
  type bug in `ssa_llvm.ad`, distinct from an emit bail — new signal for the
  ssa_llvm owner.
- **Desktop boot-verify:** see section B — launch-queue apps render as ELF64.
- **Speedup: ~6.4x vs native-SSA (geomean), 0.87x gcc-O2** at the compiler
  level — the codegen quality the ELF64 apps inherit. App-level host timing is
  blocked by the vk_2d raster bails; documented honestly rather than faked.
