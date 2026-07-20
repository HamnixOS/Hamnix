# JS engine performance: hambrowse vs Chrome/V8

**Question (USER):** "Run that website that does browser performance, then
side-by-side compare Chrome and our new browser to see how we stack up — it
should really stretch the JavaScript side."

---

## UPDATE 2026-07-20 — re-run after the GC landed

Since the first pass below, the value-cell mark-sweep GC (Phase 1) **and** the
env-scope mark-sweep GC (Phase 3) both landed (`lib/web/js/gc.ad`). This is the
re-measurement the USER asked for. Headline of the re-run:

- **The dominant blocker is GONE.** Gaps #1 and #3 below (the monotonic value
  arena and the unguarded env-arena call-cliff) are **fixed**. Empirically a
  plain numeric loop now completes **5,000,000** boxed-value allocations, and a
  call-in-loop kernel completes **1,000,000** function-call frames — both to a
  checksum that matches V8 bit-for-bit. Pre-GC these exhausted at ~400–500k value
  allocs / a few tens of thousands of frames. New gate:
  `scripts/test_jsengine_gc_unblocks_host.sh` (fixtures in
  `tests/fixtures/jsbench_gc/`).
- **Speed is unchanged: geomean ~34.9x slower than V8** across the same 15
  kernels (was ~32.5x; within run-to-run noise). The GC does **not** fire on the
  non-exhausting kernels (they stay under the arena water mark), so it added no
  measurable interpreter tax. The interpreter-vs-JIT ratio is the same honest
  ~30x. Good news: GC bought completeness for free.
- **The new #1 ceiling is the STRING pool, which is *not* GC'd.** `sp_buf` (8 MiB)
  + the `MAX_STR = 200,000` id table are still bump-only — every `"a"+i` concat
  permanently consumes a string id. A loop that manufactures a fresh string per
  iteration exhausts it at ~200k string allocs (~100k such iterations). This is
  what `test_jsengine_ceiling_host.sh` is bound by, and the single biggest
  remaining JS-engine gap for real-scale string/DOM-text work.
- **Concrete fix landed here:** string-pool exhaustion now fails **cleanly**.
  `bld_end()` (the string-builder behind `+` concatenation) was **unguarded** —
  when the pool was full it wrote `st_off/st_len[n_strs]` with `n_strs >= MAX_STR`,
  out of bounds into adjacent BSS (the intern table / globals), which surfaced as
  a *spurious* `ReferenceError: console is not defined` instead of a catchable
  "string pool exhausted". `str_new()` already guarded this identical case;
  `bld_end()` was missed. Now both fail cleanly. Gate:
  `scripts/test_jsengine_strpool_clean_host.sh`. (This closes the gap-#2
  "pool-exhaustion mis-reports" item for the string arena.)

**Where hambrowse's JS stands vs Chrome/V8 (honest):** every classic SunSpider
compute kernel runs correctly, and with GC the engine now sustains multi-million
allocation loops — it is no longer toy-scale. It remains a tree-walking
interpreter ~30–35x slower than V8's JIT (expected; a JIT is the only way to
close that, and is a large separate effort). The next real capability ceiling is
not speed but the un-GC'd string pool. Ranked next-gaps updated at the bottom.

---

**What this is:** a side-by-side JavaScript **compute** benchmark of hambrowse's
native JS engine (`lib/web/js/`, the same engine the browser and the native `js`
tool use) against **V8** — the engine inside Chrome/Chromium (measured through
`node`, which embeds the identical V8). We deliberately use pure-JS compute
kernels (SunSpider / Kraken-style: bit ops, transcendental math, crypto
MD5/SHA-1, array sort, recursion, N-body, string assembly) rather than a full
Speedometer/JetStream SPA — those are heavy DOM apps our engine cannot yet host,
so they would measure DOM completeness, not "the JavaScript side" the USER asked
to stretch.

- Suite: `tests/fixtures/jsbench/*.js` (15 kernels, self-contained, deterministic;
  each prints a `RESULT:` checksum so correctness is verified bit-for-bit).
- Harness: `bash scripts/jsbench_compare.sh` (host-only, QEMU-free).
- Reproduce: `REPS=5 bash scripts/jsbench_compare.sh`.

## Headline

- **Completeness: 15 / 15 kernels RUN correctly** in hambrowse and match V8's
  output bit-for-bit — after two engine fixes made here (`Math.pow` fractional
  exponents; `Math.asin/acos/atan/atan2`, see below). Our JS is complete enough
  to run every classic SunSpider compute kernel.
- **Speed: geomean ~32x slower than V8 (compute-only).** hambrowse is a
  tree-walking interpreter; V8 is a JIT (Ignition + TurboFan). A large gap is
  expected and honest. Range: 20x (crypto-md5, array-sort) to 63x (fannkuch,
  array-index-heavy).
- **The real ceiling is not speed, it's a no-GC value arena.** Every kernel here
  had to be scaled DOWN 10–100x from standard SunSpider sizes, because the
  engine never frees JS values (see gap #1). At full SunSpider scale every kernel
  exhausts the pool. That — not the 32x — is the highest-value JS-engine work.

## Scorecard

Compute-only, best-of-5, cold single-shot, on this dev host. `hb` = hambrowse
(`build/host/js_host`); `ref` = node v20.19.2 (V8). Ratio = hb / ref.

| benchmark | runs? | hb (ms) | V8 (ms) | ratio (hb/V8) |
|---|---|---:|---:|---:|
| `access-binary-trees` | Y | 45.78 | 1.89 | 24.2x |
| `access-fannkuch` | Y | 150.59 | 2.40 | 62.7x |
| `access-nbody` | Y | 192.00 | 5.60 | 34.3x |
| `array-sort` | Y | 6.88 | 0.32 | 21.5x |
| `bitops-3bit` | Y | 54.05 | 1.17 | 46.2x |
| `bitops-bits` | Y | 49.99 | 1.23 | 40.6x |
| `bitops-nsieve` | Y | 96.01 | 1.94 | 49.5x |
| `controlflow-recursive` | Y | 25.47 | 1.17 | 21.8x |
| `crypto-md5` | Y | 30.56 | 1.52 | 20.1x |
| `crypto-sha1` | Y | 80.55 | 1.73 | 46.6x |
| `math-atan` | Y | 166.93 | 5.25 | 31.8x |
| `math-cordic` | Y | 37.49 | 1.07 | 35.0x |
| `math-partial-sums` | Y | 51.86 | 1.93 | 26.9x |
| `math-spectral-norm` | Y | 36.07 | 1.51 | 23.9x |
| `string-fasta` | Y | 66.12 | 2.13 | 31.0x |
| **geomean** | **15/15** | | | **~32.5x** |

### Honesty note on timing

A *naive* wall-clock comparison flatters us to ~0.6x ("we beat Chrome"), but that
is an artifact: node/V8 process startup is ~90 ms and dwarfs these (necessarily
small) kernels, while hambrowse's freestanding host driver starts in ~0.9 ms. To
avoid that lie, **V8 compute is measured internally** with `process.hrtime`
around a single cold `eval` of the kernel source (startup excluded); hambrowse is
timed by external wall clock (its ~0.9 ms startup is <2% of every kernel — its
`Date.now()` is frozen, so in-process timing isn't available). Both engines are
timed cold and single-shot: the fair "run this script once" comparison. The 32x
is the honest number.

## Ranked JS-engine gaps (highest-value work first)

> **STATUS 2026-07-20:** #1 (value arena) and #3 (env call-cliff) are **FIXED**
> by the value-cell + env-scope GC. The current ranked list is: **(1) no GC on
> the STRING pool** (was gap #2's sibling; now the dominant remaining ceiling —
> exhausts at ~200k string allocs), **(2) the ~30–35x interpreter-vs-JIT tax**
> (needs a JIT; large separate effort), **(3) native-stack recursion limit**
> (old #4, still open). The mis-reporting half of #2 is now fixed for the string
> pool (clean "string pool exhausted"). Original list kept below for the record.

These are the todos this benchmark exposed, ranked by how much they block real
JS. #1–#3 are *why the kernels had to be shrunk*; they matter far more than the
32x interpreter tax.

1. **[FIXED 2026-07-20] No garbage collection — monotonic value arena (dominant blocker).**
   `lib/web/js/value.ad:mk_val` bump-allocates from a fixed `MAX_VAL = 1_000_000`
   slot pool and **never reclaims** (`n_vals` resets only at `js_init`). Every
   boxed number/temporary in a loop leaks. Empirically a plain numeric loop
   exhausts the pool at **~100k iterations**. Consequence: no real-scale compute
   loop can run; all 15 kernels here were scaled down 10–100x to fit. This is the
   single highest-value JS-engine project — even a simple mark/reclaim at
   statement or loop-iteration boundaries would unlock full-scale benchmarks.
2. **Pool-exhaustion corrupts silently and mis-reports.** When the value pool
   fills, `mk_val` returns a reused slot; downstream this surfaces as misleading
   `ReferenceError: X is not defined` or a raw **SIGSEGV**, not a clean
   "out of memory." Several kernels first *looked* like missing-feature bugs
   (`add32 is not defined`, `Angles is not defined`) that were purely pool
   exhaustion. At minimum, propagate the existing "value pool exhausted" error
   as a hard, catchable throw and stop evaluation.
3. **[FIXED 2026-07-20] Severe superlinear cliff in function-call-heavy loops.** A call-in-loop
   kernel runs 30 outer iters in 0.06 s but 40 iters in >40 s — a cliff, not a
   curve. `env`/`bind` arenas (`MAX_ENV = 80_000`, `MAX_BIND = 250_000`) are
   bump-allocated per call and, unlike the value pool, are **unguarded** — an
   overflow writes out of bounds (segfault/corruption) with no error. Related to
   #1/#2; guarding these and freeing per-call frames is the fix.
4. **Native-stack recursion limit.** Deeply recursive kernels (ack/tak/fib at
   SunSpider depth) SIGSEGV the tree-walking evaluator (host-thread stack
   overflow) instead of throwing `RangeError: Maximum call stack size exceeded`.
   `controlflow-recursive` had to cap depth. Add an interpreter recursion-depth
   guard that throws.
5. **`Math.pow` general exponent — FIXED here.** Was integer-exponent + `x^0.5`
   only; every other fractional exponent returned `NaN` (broke
   `math-partial-sums`). Now `x^y = exp(y·ln x)` for `x>0`, correct 0/negative
   handling. Matches V8 to full printed precision.
6. **Inverse trig `Math.asin/acos/atan/atan2` — ADDED here.** Were entirely
   missing (`atan2 is not a function`) and are used across 3d/cordic/graphics
   math. Implemented extern-free (atan via argument-halving + Maclaurin; asin/acos
   via atan; atan2 with quadrant handling). Also noticed missing: `Math.fround`
   (low priority).

## Fixes landed with this benchmark (additive, gated)

All in `lib/web/js/` (behavior-additive; existing `test_jsengine_host` and
`test_hambrowse_host` gates stay green; native `js` tool still compiles):

- `util.ad`: general `f_pow` (fractional/negative exponents); new `f_atan`,
  `f_asin`, `f_acos`, `f_atan2`, `f_pi`.
- `consts.ad` / `setup.ad` / `builtins/collections.ad`: register + dispatch
  `Math.asin/acos/atan/atan2`.

Verified vs V8: `Math.atan(1)=0.785398163…`, `Math.atan2(3,-4)=2.498091544…`,
`Math.pow(3,2.5)=15.588457268…`, `Math.pow(2,-0.5)=0.707106781…` — all match to
the digits hambrowse prints.

## How the kernels were sized

Standard SunSpider iteration counts exhausted the value arena (old gap #1), so
each kernel's outer loop was reduced to fit while remaining a faithful
implementation (same algorithm, same per-iteration work, deterministic
checksum). The ratios are *representative of the interpreter-vs-JIT tax per unit
work*.

**Update 2026-07-20:** with the value + env GC landed, the *pure-numeric* kernels
here no longer need to be shrunk — the engine sustains multi-million-iteration
loops (see `tests/fixtures/jsbench_gc/`). The fixtures in
`tests/fixtures/jsbench/` are kept small deliberately so `jsbench_compare.sh`
stays a fast, low-noise gate; the ratio is scale-invariant, so a bigger N would
report the same ~35x. The remaining kernels that still *cannot* be scaled to full
SunSpider length are the **string-heavy** ones (fasta at 2M chars, any per-iter
string manufacture) — they hit the un-GC'd string pool (~200k string allocs),
now surfaced as a clean "string pool exhausted".
