# Adder host performance baseline

How fast is the Adder language, compiled native? This is the standing
baseline for the `x86_64-linux` Adder target measured against C
(`gcc -O0` / `-O2`) and CPython, across a spread of integer workloads.

Reproduce with **`bash scripts/bench_adder_host.sh`** (pure host tooling —
no QEMU, no Hamnix image). Each benchmark lives in three languages under
`tests/bench/<name>.{ad,c,py}` and computes an identical result; the
script asserts all implementations AGREE before timing. Pass
`BENCH_OPT=1 bash scripts/bench_adder_host.sh` to bench the **`-O1`
peephole optimizer** (Track 6) instead of the default single-pass backend.

## `-O1` optimizer landed (Track 6, 2026-06-20)

The single-pass backend now has an optional **`-O1` peephole optimizer**
(`adder/compiler/peephole_x86.py`, gated behind `-O1`; the default `-O0`
single-pass path — the one the Hamnix image build uses — is unchanged).
It rewrites the emitted assembly with four strictly-local, provably-safe
transforms (condition→branch fusion, dead store-reload elimination,
immediate-push folding, and push/pop→scratch-register forwarding that
unwinds the stack-machine's memory round-trips). Validated by the
predicted-output fuzzer at `-O1` (`FUZZ_OPT=1 scripts/fuzz_adder.sh`,
also `ADDER_FUZZ_OPT=1 tests/fuzz/adder_fuzzer.py`) — **0 miscompiles**
over tens of thousands of random programs — and by the cross-language
AGREEMENT check above running at `-O1`.

**Before → after (same machine, best-of-7, Python skipped):**

| bench | C ‑O2 | Adder ‑O0 | `-O0`/‑O2 | Adder ‑O1 | `-O1`/‑O2 | O0→O1 |
|---|--:|--:|--:|--:|--:|--:|
| collatz | 0.181s | 1.158s | 6.40× | 1.071s | 5.92× | 1.08× |
| fib     | 0.030s | 0.127s | 4.23× | 0.089s | 2.97× | 1.43× |
| sieve   | 0.013s | 0.046s | 3.54× | 0.034s | 2.62× | 1.35× |
| mmul    | 0.017s | 0.131s | 7.71× | 0.095s | 5.59× | 1.38× |
| lcg     | 0.048s | 0.089s | 1.85× | 0.091s | 1.90× | 0.98× |

**Geometric means:** the optimizer moves Adder from ≈**4.24×** to
≈**3.45×** of C `-O2` — a **1.23× overall speedup**, biggest on the
call/loop-heavy `fib` (1.43×), `mmul` (1.38×) and `sieve` (1.35×).
`lcg` is unchanged (within noise): its dependent multiply chain is
latency-bound, so removing instructions doesn't help — exactly as the
baseline analysis predicted.

## Baseline (2026-06-20, single-pass `-O0`)

Host: Intel Core i7-8086K @ 4.00 GHz · gcc 14.2.0 · CPython 3.11.10.
Compiled times are best-of-3; Python best-of-1.

| bench | Adder | C ‑O0 | C ‑O2 | Python | Adder/‑O2 | stresses |
|---|--:|--:|--:|--:|--:|---|
| collatz | 1.239s | 0.395s | 0.183s | 9.053s | 6.76× | integer + branches |
| fib | 0.135s | 0.099s | 0.032s | 2.535s | 4.16× | recursion / calls |
| sieve | 0.045s | 0.039s | 0.013s | 1.146s | 3.36× | memory-bound |
| mmul | 0.136s | 0.062s | 0.017s | 3.674s | 7.83× | array-address math |
| lcg | 0.090s | 0.097s | 0.048s | 7.131s | 1.87× | pure ALU chain |

**Geometric means:** the un-optimized single-pass backend is ≈**1.6×**
slower than `-O0`, ≈**4.3×** slower than `-O2`, and ≈**24×** *faster*
than CPython.

## Reading the numbers

- **Adder is already in unoptimized-C territory** (~1.6× off `-O0`), and
  on the pure-ALU `lcg` chain it *ties* C — the dependent multiply chain
  is latency-bound, so codegen quality barely matters. The single-pass
  backend is a sound foundation, not a bad code generator.
- **~24× faster than CPython** on average (up to ~79× on `lcg`, where
  CPython's arbitrary-precision int masking dominates). As a systems
  language it behaves as you'd want.
- **The `-O2` gap is where an optimizer pays off, and it's uneven:**
  - Biggest gaps — **mmul** and **collatz**: redundant address/index
    recomputation (`i*DIM+k` every iteration) and loop-invariant work
    that `-O2` hoists and strength-reduces.
  - Smallest gap — **lcg**: nothing to optimize; latency-bound.

## What `-O1` does, and what's next

The `-O1` peephole pass attacks the single-pass backend's two structural
inefficiencies directly: the **stack-machine memory traffic** (every
binary op spills an operand through `push`/`pop`) and **redundantly
materialised constants/booleans**. Forwarding push/pop pairs through the
otherwise-unused caller-saved scratch registers (`%r8`–`%r11`) and fusing
`setCC`→`testq`→`jz` into a single `jCC` removes a large fraction of the
per-operation overhead — hence the wins on the call/branch/loop-heavy
benchmarks.

The remaining gap to `-O2` is the deeper, IR-requiring optimizations the
peephole *cannot* express locally: **loop-invariant code motion**,
**strength reduction** of index math (`i*DIM+k`), **CSE**, and real
**register allocation** to keep loop variables out of memory entirely.
Those still want a minimal IR between AST and x86 emission. The `-O1`
peephole is the first, lowest-risk increment toward the **rough-C-territory
(≤ ~2× of `-O2`)** goal tracked as **Track 6** in [`TODO.md`](../TODO.md);
the IR-based passes are the next increment.

> Caveats: microbenchmarks on one machine; integer-only (Adder has no
> floats); Python best-of-1; `-O2` benefits from auto-vectorization a
> scalar Adder optimizer won't match. Treat as ballpark, not a leaderboard.
