# Loop-rotation lever — rigorous NEGATIVE result (DO-NOT-MERGE)

Date: 2026-07-18. Bench suite `tests/bench/opt/`, four-way host harness
`scripts/bench_opt.sh`. Host: x86_64-linux, gcc -O2 reference. Baseline =
current tree (after the four converting levers: float-XMM, float-const-hoist,
call-arg-routing, fused-store-register), geomean ~1.47–1.50× of gcc-O2.

## What was tried

The single structural thing gcc -O2 does in EVERY loop that the Adder backend
never did: **bottom-test loop rotation**. The seed / current Adder codegen emits
the un-rotated shape

```
.top: <test cond -> jcc .exit>   ; body ; jmp .top ; .exit:
```

which runs the condition-false test AND an unconditional back-`jmp` every
iteration = **two branch slots + one extra instruction per trip**. gcc rotates
to a single bottom test:

```
jmp .cond ; .top: <body> ; .cond: <test cond -> jcc .top> ; .exit:
```

steady state = `<body>` + one taken conditional back-branch. A prototype
implemented this in `gen_while` (gated under `--opt`/`isel_is_enabled`, refused
when the body contains a `continue` since a rotated loop's test sits after the
body). It fired on every while loop in every loop-bound kernel.

## Correctness: PASS (the transform is sound)

- flag-OFF byte-identity objdiff `scripts/test_native_vs_seed_objdiff.sh`:
  **307/307 clean, 0 divergences** (the lever is behind `--opt`; the default
  build is untouched).
- differential fuzzer `ADDER_OPT=1 scripts/fuzz_adder_diff.sh`: **PASS**, 0
  miscompiles across the 500-program soak + every opt corpus.
- all eight kernel checksums AGREE ON and OFF (matmul 1886692650, sieve 1787196,
  licm 53068958052892, dcecopy 6400000000000000, tak 36, collatz 103275238,
  mandel 6712881, saxpy 10116645105).

The transform is correct and DOES reduce per-iteration instruction + branch
count in every loop. Verified instruction-for-instruction, e.g. the matmul inner
k-loop went 11 instrs / 2 branches -> **10 instrs / 1 branch**, body 32B-aligned;
the sieve clear loop 5 instrs / 2 branches -> **4 instrs / 1 branch**, aligned.

## Wall-time: NET REGRESSION (~2% slower) — does NOT convert

Interleaved same-run A/B (BEFORE = tree without rotation, AFTER = +rotation,
both `--opt`, best-of-N alternated to share host state; two runs, tight
variance):

| kernel  | AFTER/BEFORE wall | verdict         | bound by            |
|---------|-------------------|-----------------|---------------------|
| dcecopy | 0.872–0.876×      | **win −13%**    | ALU, L1-resident    |
| licm    | 0.934–0.939×      | **win −6%**     | ALU, L1-resident    |
| mandel  | 0.993–1.004×      | neutral         | float latency chain |
| tak     | 0.998–1.000×      | neutral         | recursion (no loop) |
| collatz | 1.031×            | slight regress  | data-dependent branch |
| saxpy   | 1.093–1.114×      | **regress +10%**| streaming bandwidth |
| matmul  | 1.117–1.125×      | **regress +12%**| strided B, mem latency |
| sieve   | 1.129–1.141×      | **regress +13%**| bandwidth           |
| geomean | **1.020–1.022×**  | **NET SLOWER**  |                     |

## Why it regresses — the residual is memory-bound, not front-end-bound

The wins are exactly the two compute/ALU-bound single loops whose working set is
L1-resident (bucket[64]); there the front end is the bottleneck and removing a
branch/instruction converts to wall time.

The losses are the mid-pack + heavy kernels (matmul, sieve, saxpy), all of which
are memory-bound:

- **matmul** inner k-loop is bound by the strided `B[k*N+j]` load
  (`imul rax,[r15+r11*8]`, r11 strides N·8 = 512 B — a fresh cache line almost
  every access, walking a column). The AFTER loop is strictly better in the
  front end (10 vs 11 instrs, 1 vs 2 branches, aligned) yet 12% slower: the core
  is stalled on memory, so front-end slack cannot help.
- **sieve** clear/count loops stream 2 MB arrays × 12 passes — store/load
  bandwidth bound; the AFTER clear loop is 4 vs 5 instrs / 1 vs 2 branches and
  still slower.
- **saxpy** is unit-stride streaming over two 1 M arrays — bandwidth bound.

On a memory-bound loop the front end already has slack, so fewer instructions do
not speed it up; and rotation shifts every downstream code offset, perturbing
the tuned per-loop 32B-alignment heuristic (`emit_loop_align`), which nudges
these sensitive loops the wrong way. The two effects together make it a
reproducible net regression.

## Decision and implication

**DO-NOT-MERGE.** Blanket loop rotation is correct but a net wall-time
regression on this suite/host. Gating it to only the winning kernels has no
honest compile-time predicate (licm/dcecopy also write arrays; the only thing
that separates them is L1-residency vs multi-MB working set — that is
benchmark-gaming, not a universal win), so it is not salvageable as a codegen
lever.

More importantly this pins the codegen-lever floor. The remaining Adder-vs-gcc
hot-path deltas on the mid-pack are:

1. **Memory-boundedness** (matmul strided B, sieve/saxpy streaming, collatz
   data-dependent branch) — NOT addressable by any front-end codegen lever; this
   is the established non-converting floor.
2. **Round-trip through `rax`** (`mov rax, X ; mov Y, rax` — seen in the
   licm/dcecopy/saxpy loads) and **missed integer strength-reduction of
   affine-in-IV expressions** (dcecopy recomputes `i*2+1` with an `imul` each
   iteration where gcc keeps a strength-reduced `add rcx,2`). Both are
   register-allocation / value-numbering problems: the current backend
   materialises every expression into `rax` and then copies to the SSA temp's
   home. A local peephole cannot fix them safely (rax-liveness is not locally
   decidable without risking a miscompile).

The next real parity step is therefore NOT another peephole/structure lever but
the **P1-IR stack-machine rewrite** (`docs/perf_p1_isel_design.md`): a proper
value IR with real register allocation kills the round-trip-through-rax, enables
general strength-reduction, and lets the scheduler overlap the memory-bound
loads — which is where the remaining gcc gap actually lives.
