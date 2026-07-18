# P1 Phase-5 increment 1 — multiply-add DAG tile + the honest gap-to-1.0× diagnosis

Date: 2026-07-18. Bench suite `tests/bench/opt/`, four-way host harness
`scripts/bench_opt.sh`, gcc-O2 reference on x86_64-linux (i7-8086K @ 4.0 GHz,
gcc 14.2.0). Baseline geomean **1.47× of gcc-O2** (after the five converging
levers; see `docs/perf_pow2_parity_result.md`,
`docs/perf_looprot_negative_result.md`, `docs/perf_sub8_load_fuse_negative_result.md`).

This documents (1) the per-kernel diagnosis of the residual gap to 1.0×, with an
honest verdict on whether an **auto-vectorizer** is required, and (2) the first
Phase-5 DAG-tiler increment landed — the `x*{2,3,5,9}(+/-imm)` → single-`lea`
maximal-munch tile.

---

## 1. The gap to 1.0×, per kernel — is it (A) scalar isel or (B) vectorization?

Disassembled each kernel Adder-`--opt` vs gcc-O2 and categorized the residual.

### The vectorization question, answered from the object code

**gcc-O2 emits ZERO packed-SIMD in the hot compute loop of EVERY kernel on this
suite.** Grepping each `c_*_O2` binary for `xmm/ymm/padd/pmul/movdqa/pcmp`:

| kernel | packed-SIMD in a hot loop? | what the SIMD (if any) is |
|---|---|---|
| matmul | **no** | 8 `paddq`/`movdqa` — the *checksum-reduction tail* only (sum result[] once) |
| licm | **no** | 7 `paddq` — checksum tail only |
| dcecopy | **no** | 7 `paddq` — checksum tail only |
| sieve | **no** | 0 SIMD anywhere (clear = `memset@plt`; count = scalar `cmp/adc`) |
| saxpy | **no** | 0 SIMD anywhere (scalar `imul`/`lea` update loop) |
| collatz | **no** | 0 |
| tak | **no** | 0 |
| mandel | **no** | 31 `xmm` ops, but all **scalar doubles** (`addsd`/`mulsd`/`cvtsi2sd`) — the x86-64 float ABI, NOT vectorization |

So the task brief's hypothesis — "sieve's byte scan, saxpy's `y+=a*x`, matmul's
inner product are all vectorizable — gcc emits packed SSE/AVX" — is **false at
-O2 on this suite.** gcc -O2 keeps every hot compute loop scalar (matmul's B is
strided; saxpy/sieve's `-O2` does not turn on the cost-model vectorizer; the only
packed adds are the trivial O(N) checksum tails, a negligible slice of runtime).
This confirms the two prior gap-anatomy docs. **An auto-vectorizer buys ≈0× on
this suite and is NOT the blocker to 1.0×.**

### Per-kernel A-vs-B split (A = scalar-tiler-addressable, B = SIMD)

| kernel | ON/C-O2 | bound by | (A) scalar-tiler addressable | (B) SIMD |
|---|---:|---|---|---|
| collatz | 1.92× | data-dependent branch, compute | **large**: `3n+1`→lea (this increment), signed `/2` fixup (4→1 instr, needs `n>0` range analysis, 3/iter), `and;cmp $0`→drop cmp | 0 |
| sieve | 1.84× | streaming bandwidth (2 MB ×12, cache-cold) | **~0** (memory-bound; the sub-8 load-fuse *regressed* +7%, looprot +13%) | 0 (gcc uses memset+scalar) |
| tak | 1.62× | recursion call overhead | **large**: gcc turns the 3rd self-call into a loop + keeps args in callee-saved regs; Adder does full call/prologue each time | 0 |
| mandel | 1.51× | float latency chain | small (already scalar SSE, movaps) | 0 |
| matmul | 1.43× | strided-B memory latency | small: `%rax` round-trips, base recompute; the loads dominate | 0 (checksum-tail paddq only) |
| dcecopy | 1.33× | ALU, L1-resident | medium: `i*2+1` recomputed via `imul` (tile applies via the sel-path *next stage*); IV strength-reduction | 0 (checksum tail) |
| saxpy | 1.28× | streaming bandwidth (2×1 M) | **~0** (memory-bound) | 0 (gcc scalar) |
| licm | 1.14× | ALU, L1-resident | small residual | 0 (checksum tail) |

### Achievable geomean with a scalar tiler ALONE — the honest number

The suite splits cleanly:

* **Compute-bound (collatz, tak, dcecopy, licm, mandel):** category-A residuals a
  scalar tiler CAN close. Optimistic post-scalar-tiler targets: collatz ~1.5
  (range analysis + lea + flag peephole), tak ~1.25 (self-tail-recursion → loop),
  dcecopy ~1.15, mandel ~1.30, licm ~1.10.
* **Memory-bound (sieve 1.84, saxpy 1.28, matmul 1.43):** category NEITHER. The
  two negative-result docs *proved* that reducing instruction count on these does
  **not** convert — looprot was +13% on sieve, the sub-8 load-fuse +7% — because
  the front end already has slack and gcc's load *addressing/scheduling* (simple
  vs indexed addressing, overlap) is the real edge. A scalar tiler cannot close
  these, and (per §1) neither can a vectorizer. They stay ~1.4–1.8×.

Recomputing the geomean with the compute-bound kernels at their scalar-tiler
targets and the memory-bound trio held at the floor (sieve 1.80, saxpy 1.20,
matmul 1.35):

```
geomean( 1.35, 1.80, 1.10, 1.15, 1.25, 1.50, 1.30, 1.20 ) ≈ 1.31×
```

**So ~1.3× is the honest ceiling for a scalar tiler alone on this suite, and it is
floored by the memory-bound array kernels — NOT by missing vectorization.** 1.0×
is **not** reachable here without matching gcc's exact streaming-load
addressing/scheduling microarchitecture on sieve/saxpy/matmul (a deep
backend-scheduling investment), and a vectorizer would not help because gcc does
not vectorize them either. **The blocker to 1.0× is the memory-bandwidth/latency
floor on the array kernels, not an auto-vectorizer.**

---

## 2. Phase-5 increment 1 — the multiply-add DAG tile (`x*{2,3,5,9}(+/-imm)` → one `lea`)

The first genuine **maximal-munch DAG tile** on the destination-driven backend:
greedily match the three-node pattern `(ADD/SUB (MUL x m) d)` (and the bare
`(MUL x m)`) and collapse it to a single `lea disp(%rax,%rax,scale),%rax`, where
`m ∈ {2,3,5,9}` (via SIB `base==index==%rax`, scale `1/2/4/8`) and `d` is an
imm32 displacement. This is the x86 strength-reduced form gcc uses.

* `codegen.ad` `emit_lea_muladd_rax(sbits, disp)` — the encoder (48 8D + SIB, mod
  00/01/10 for disp 0/8/32). `lea_mul_sbits(m)` maps {2,3,5,9}→{0,1,2,3}.
* `try_lea_muladd_tile(v)` — the matcher, called in the `IR_BINOP` arm of
  `gen_expr_ir` **before** the reassoc / per-node MUL+ADD arms. Matches
  `MUL(x,m)`, `ADD(MUL(x,m),d)`/`ADD(d,MUL(x,m))`, `SUB(MUL(x,m),d)`; `x` is the
  sole non-const operand, evaluated ONCE into `%rax` then used as both lea base
  and index (no re-eval, no side-effect duplication — the IR lowers only pure
  subtrees). `m`,`d` must be IR_CONST in [0, 0x7FFFFFFF] so `d`/`-d` fit a
  sign-extended int32 lea disp; anything else falls through unchanged.

**Correctness:** `lea` computes `x*m+d` in full 64-bit two's-complement,
identical for signed and unsigned; it sets no flags and `gen_expr_ir` does not
export flags, so dropping the replaced `add`'s flag side effect is sound. Gated
entirely behind `--opt` (`isel_is_enabled()`); the default build never reaches it.

### Disassembly — collatz `3*n+1`

```
BEFORE (--opt)                          AFTER (--opt)
102ee: mov  rax,r13                     ...
102f1: imul rax,rax,0x3                 102f1: lea rax,[rax+rax*2+0x1]   ; one instr
102f5: add  rax,0x1                      (mov rax,r13 + lea)
102f9: mov  r13,rax
```

Exactly gcc-O2's `lea rax,[rax+rax*2+0x1]`. The `imul $3 ; add $1` pair → one lea.

### Reach

Fires wherever the pattern reaches `gen_expr_ir`: collatz `3*n+1` (the
`n=3*n+1` RHS re-reads `n`, so the dest-driven `sel` path defers to
`gen_expr_ir` — the tile fires), plus the array-init `i*3+7`/`i*5+1` shapes. The
`dcecopy`/`saxpy` hot `i*2+1` goes through the newer dest-driven `sel_*` path
(which computes into an arbitrary home register and currently emits `imul $2 ;
add $1`) — extending the tile there is the **next stage** (§4).

---

## 3. Bench — converts on collatz, geomean neutral-to-positive

`rm -rf build/fuzz_ad_codegen` first; `BENCH_NO_DOC=1 BENCH_REPS=7`, both `--opt`:

| kernel | BEFORE ON/C-O2 | AFTER ON/C-O2 |
|---|---|---|
| collatz | 1.92× | 1.88× |
| geomean | 1.47× | 1.47× |

Rigorous interleaved same-host A/B on the two `--opt` collatz ELFs (best-of-25,
alternated per trial): **AFTER/BEFORE = 0.973** — a consistent ~2.7% wall-time
win on the worst compute-bound kernel (every AFTER sample below the paired
BEFORE), converting the removed instruction. Geomean is neutral this round
(collatz is one of eight; the memory-bound majority is unmoved), but the tile is
a converging foundation and every checksum agrees.

---

## 4. Invariants + next stage

**Invariants (this increment):**
* flag-OFF byte-identity `scripts/test_native_vs_seed_objdiff.sh`: 307/307 clean,
  0 divergences (tile behind `--opt`; default build untouched).
* differential fuzzer `scripts/fuzz_adder_diff.sh`: 500/500, 0 miscompiles.
* new focused gate `scripts/test_opt_leamuladd.sh`: 1560 cases, 0 fails — `x*m`,
  `x*m+d`, `x*m-d`, `m*x` over m∈{2,3,5,9} (+ non-tile controls 6,7), d up to
  imm32, x negative / INT_MIN / ±2^k edges, ON==OFF==64-bit-ref.
* all eight bench checksums AGREE (collatz 103275238, matmul 1886692650,
  sieve 1787196, licm 53068958052892, dcecopy 6400000000000000, tak 36,
  mandel 6712881, saxpy 10116645105); native self-hosts; float paths untouched
  (movaps, not movsd).

**Next stage (roadmap toward the ~1.3× scalar ceiling):**
1. **Extend the lea multiply-add tile onto the dest-driven `sel_*` path** — emit
   `lea disp(%src,%src,scale),%dst` reading a promoted-register operand directly
   (no `%rax` hop) into an arbitrary home register. Reaches dcecopy/saxpy's
   `i*2+1` and collatz's `3*n+1` in one instruction (drops the `mov rax,r13`).
2. **collatz signed `/2` range analysis** — prove `n>0` from the `while n>1`
   guard so `n/2` lowers to `sar $1` (1 instr) instead of the 4-instr sign fixup
   (3 instrs/iter, every iteration — the single biggest remaining collatz win).
3. **`and`/flag-consuming compare peephole** — a `(expr & mask) == 0`/`!= 0`
   branch drops the redundant `cmp $0` after the flag-setting `and` (collatz
   parity, universal). Requires modelling flag-liveness at the compare boundary.
4. **tak self-tail-recursion → loop** + callee-saved arg residency (the largest
   single lever left, ~1.62→~1.25, but a substantial structural pass).

Items 2–4 are the compute-bound residual; none of them is vectorization. The
memory-bound array kernels (sieve/saxpy/matmul) are the ~1.3× floor and are not
addressable by isel or SIMD on this suite.
