# POW2 parity/divisibility idiom fold — CONVERTING result (MERGE)

Date: 2026-07-18. Bench suite `tests/bench/opt/`, host four-way harness
`scripts/bench_opt.sh`, gcc -O2 reference on x86_64-linux. This closes the last
ALGEBRAIC Adder-vs-gcc gap on the worst compute-bound holdout (`collatz`), the
one both prior negative results named as the residual:
`docs/perf_sub8_load_fuse_negative_result.md` §6 and
`docs/perf_looprot_negative_result.md` (collatz's `n - (n/2)*2` parity vs gcc's
`and n,1`).

## The gap (disassembly)

`collatz.ad`'s hot inner loop tests parity with the classic split idiom
`half = n / 2; if n - half * 2 == 0:`. The destination-driven backend lowered it
literally (`--opt`, BEFORE):

```
mov  %r13,%rax ; mov %rax,%rcx ; sar $0x3f,%rax ; shr $0x3f,%rax
add  %rcx,%rax ; sar $0x1,%rax ; mov %rax,%r15        ; half = n/2 (signed fixup)
mov  %r15,%rax ; imul $0x2,%rax,%rax ; mov %rax,%rdi
mov  %r13,%rax ; sub  %rdi,%rax ; cmp $0x0,%rax ; jne ...   ; n - half*2 == 0
```

gcc -O2 emits `sar $1,%rcx` (half) + `test $0x1,%al` (parity). The whole
`imul $2 ; sub` sequence is where the 2.05× lived.

## The lever (opt.ad Phase 9.5, `opt_paritymod_function`)

An AST algebraic pass, `--opt`-gated (so flag-OFF output is byte-identical),
inserted after copy-prop and before DCE. Over each straight-line run it tracks a
small map `q = x / C` (C a power of two) built from preceding `ND_VAR_DECL` /
`ND_ASSIGN` statements, killed on any write to `q` or `x` and flushed at every
control-flow boundary. When an `== 0` / `!= 0` comparison holds a
divisibility-by-pow2 idiom, its compared subtree is rewritten IN PLACE to
`x & (C-1)`:

* `x % C`                          (dividend x any expr)
* `x - (x / C) * C` / `x - C * (x / C)`      (inline div)
* `x - q * C` / `x - C * q`  with a live preceding `q = x / C`  (the collatz shape)

AFTER, the same loop tests parity with `mov %r13,%rax ; and $0x1,%rax ; cmp $0x0`
— the `imul $2 ; sub` and the `half` dependency are gone (the `half = n/2` div
itself stays; it still feeds `n = half` in the taken arm — that residual signed
`/2` fixup is gcc's range-analysis win `n>1 ⇒ sar $1`, a SEPARATE lever, not this
one).

## SIGNEDNESS — why this is correct for ANY sign

The fold fires ONLY inside an `== 0` / `!= 0` comparison, i.e. a DIVISIBILITY
test. For a power-of-two C, `x` is divisible by C ⟺ its low log2(C) bits are all
zero ⟺ `(x & (C-1)) == 0`, and this holds for EVERY sign of x — it does not
depend on the sign/rounding of `/`. (For x=-3, C=2 the idiom value `-3-(-1)*2 =
-1` and `-3 & 1 = 1` DIFFER in value, but both are non-zero, so the `== 0` test
agrees.) The pass therefore NEVER lowers a value-context signed `x % C` or
`x - (x/C)*C` to a bare `&`: a value-context `x % C` is already lowered correctly
per-sign by `gen_div_const` in codegen.ad and is left untouched. Only the
sign-independent evenness/divisibility TEST is folded. This matches the mandate
"if signedness is ambiguous, do NOT transform (correctness first)".

## Wall-time — CONVERTS, no regression

`rm -rf build/fuzz_ad_codegen` first; `BENCH_NO_DOC=1 BENCH_REPS=9 bash
scripts/bench_opt.sh`, BEFORE = HEAD~1, AFTER = this change, both `--opt`:

| kernel  | BEFORE ON/C-O2 | AFTER ON/C-O2 |
|---------|----------------|---------------|
| collatz | **2.05×**      | **1.92×**     |
| geomean | **1.48×**      | **1.47×**     |

Every other kernel unchanged within noise; all eight checksums AGREE (collatz
103275238, matmul 1886692650, sieve 1787196, licm 53068958052892, dcecopy
6400000000000000, tak 36, mandel 6712881, saxpy 10116645105).

Rigorous interleaved same-host A/B on the two `--opt` collatz ELFs (best-of-25,
alternated per trial): **AFTER/BEFORE = 0.941 best, 0.949 median** — a
consistent ~5–6% wall-time win (every AFTER sample below the paired BEFORE), not
noise.

## Invariants

* flag-OFF byte-identity objdiff `scripts/test_native_vs_seed_objdiff.sh`:
  307/307 clean, 0 divergences (the lever is behind `--opt`; default build
  untouched).
* differential fuzzer `scripts/fuzz_adder_diff.sh` (+ `ADDER_OPT=1` lane):
  500/500, 0 miscompiles.
* new focused gate `scripts/test_opt_parity_pow2.sh`: 680 cases, fold fires 648×,
  0 fails — signed int64 (negative + positive) + unsigned uint64 dividends, pow2
  divisors, `== 0` idiom + `!= 0` mod, AND value-context signed `%` left
  C-truncated.
* native self-hosts.

## Read for the frontier

collatz drops 2.05× → 1.92×. The residual vs gcc is now the signed `/2` fixup on
`half` (4 instrs vs gcc's 1) — a value-range lever (prove `n > 0`), NOT an
algebraic-plumbing one. With the parity idiom folded, the algebraic parity front
is at its honest ceiling; the remaining collatz delta is range analysis +
memory/branch boundedness, consistent with the two prior negative results.
