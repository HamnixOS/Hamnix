# Adder host performance baseline

How fast is the Adder language, compiled native? This is the standing
baseline for the `x86_64-linux` Adder target measured against C
(`gcc -O0` / `-O2`) and CPython, across a spread of integer workloads.

Reproduce with **`bash scripts/bench_adder_host.sh`** (pure host tooling —
no QEMU, no Hamnix image). Each benchmark lives in three languages under
`tests/bench/<name>.{ad,c,py}` and computes an identical result; the
script asserts all implementations AGREE before timing.

## Baseline (2026-06-20)

Host: Intel Core i7-8086K @ 4.00 GHz · gcc 14.2.0 · CPython 3.11.10.
Compiled times are best-of-3; Python best-of-1.

| bench | Adder | C ‑O0 | C ‑O2 | Python | Adder/‑O2 | stresses |
|---|--:|--:|--:|--:|--:|---|
| collatz | 1.239s | 0.395s | 0.183s | 9.053s | 6.76× | integer + branches |
| fib | 0.135s | 0.099s | 0.032s | 2.535s | 4.16× | recursion / calls |
| sieve | 0.045s | 0.039s | 0.013s | 1.146s | 3.36× | memory-bound |
| mmul | 0.136s | 0.062s | 0.017s | 3.674s | 7.83× | array-address math |
| lcg | 0.090s | 0.097s | 0.048s | 7.131s | 1.87× | pure ALU chain |

**Geometric means:** Adder is ≈**1.6×** slower than `-O0`, ≈**4.3×**
slower than `-O2`, and ≈**24×** *faster* than CPython.

## Reading the numbers

- **Adder is already in unoptimized-C territory** (~1.6× off `-O0`), and
  on the pure-ALU `lcg` chain it *ties* C — the dependent multiply chain
  is latency-bound, so codegen quality barely matters. The single-pass
  backend is a sound foundation, not a bad code generator.
- **~24× faster than CPython** on average (up to ~79× on `lcg`, where
  CPython's arbitrary-precision int masking dominates). As a systems
  language it behaves as you'd want.
- **The `-O2` gap is where an optimizer would pay off, and it's uneven:**
  - Biggest gaps — **mmul (7.8×)** and **collatz (6.8×)**: redundant
    address/index recomputation (`i*DIM+k` every iteration) and
    loop-invariant work that `-O2` hoists and strength-reduces.
  - Smallest gap — **lcg (1.9×)**: nothing to optimize; latency-bound.

## Why this matters / next step

The gap to `-O2` is concentrated in a handful of classic optimizations
(register allocation, loop-invariant code motion, strength reduction,
CSE, simple inlining) — not in anything LLVM-scale. The current backend
is single-pass with no IR, so the prerequisite is a minimal IR between
AST and x86 emission; those passes then plug in.

Goal: **rough C territory — target ≤ ~2× of `-O2`** (from today's ~4.3×),
without chasing `-O2`'s auto-vectorization. Tracked as **Track 6** in
[`TODO.md`](../TODO.md). Re-run this fixture as passes land and watch the
Adder/`-O2` column fall.

> Caveats: microbenchmarks on one machine; integer-only (Adder has no
> floats); Python best-of-1; `-O2` benefits from auto-vectorization a
> scalar Adder optimizer won't match. Treat as ballpark, not a leaderboard.
