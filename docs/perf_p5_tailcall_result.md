# P1 Phase-5 increment 2 — self-tail-call → loop (tak's outer-call lever)

Date: 2026-07-18. Bench suite `tests/bench/opt/`, four-way host harness
`scripts/bench_opt.sh`, gcc-O2 reference on x86_64-linux. Baseline geomean
**1.47× of gcc-O2** (after the DAG lea-tile increment,
`docs/perf_p5_leamuladd_result.md`). This increment lands roadmap item **#1**
(the biggest single lever): a self-recursive call in **tail position** becomes a
**loop back to the post-prologue body top**, reusing the frame instead of
call/epilogue/prologue.

## The transform

`ND_RETURN` whose value is `return f(<args>)` where `f` is the CURRENT function
(a self-tail-call) is emitted as:

1. marshal the new arguments into the SysV arg registers — **exactly** as an
   ordinary call does (`gen_call`'s contract: at the call point every argument is
   materialised in its ABI register and the old parameters are dead);
2. **replay the prologue's own** `spill_params` + `ra_emit_init_regs` — the
   identical, already-proven-sound arg-register → parameter-home transfer;
3. `jmp` back to the body top (the code offset just after the prologue's param
   spill/init).

No recursive `call`, no epilogue, no re-entered prologue — the frame is reused.

### Why replaying the prologue's param-init is sound in tail position

The prologue moves arg-registers → parameter homes and is correct by
construction. In tail position the *same* moves are correct because gen_call has
already materialised **all** new args in the arg registers (`rdi…r9`, disjoint
from the callee-saved parameter homes `rbx/r12…r15`) and the old params are dead.
`spill_params` stores every arg register to its slot (memory) *before*
`ra_emit_init_regs` loads slots/arg-regs into home registers, so even a
home-register that aliases a later arg register cannot clobber a still-live arg —
identical to the prologue's own ordering. Elided-home params move arg-reg → home
directly, but `param_home_elidable` guarantees the home is callee-saved (never an
arg register), so those moves never clobber an arg source either.

### Scope / gate

Behind `isel_is_enabled()` (`--opt`). Fires only for a plain function (not a
method) whose parameters and return type are all plain **integer-class** values
(≤6 register-passed params; no float/SSE, by-value aggregate, or Slice) —
`tail_opt_func_ok`. A keyword-normalised / defaulted call, or any non-self /
non-tail call, falls through to the ordinary path (`try_tail_self_return` returns
1 only after the loop actually fired; otherwise it finishes as a normal return —
never a double emit). Default (`--opt` off) build is byte-identical to the seed:
`cg_tail_ok` is 0 and the transform is unreachable.

### Disassembly — tak's outer `tak(tak(...),tak(...),tak(...))`

```
BEFORE (--opt)                        AFTER (--opt)
  ... 3 inner tak calls, args           ... 3 inner tak calls, args
      popped into rdi/rsi/rdx               popped into rdi/rsi/rdx
  call   tak                            mov    %rdi,%rbx        ; replay param init
  leave                                 mov    %rsi,%r12        ; (ra_emit_init_regs)
  pop    r13 ; pop r12 ; pop rbx        mov    %rdx,%r13
  ret                                   jmp    <body_top>       ; loop, reuse frame
```

The three INNER tak calls stay real calls (not in tail position); only the OUTER
self-call becomes the loop back-edge. This is exactly gcc's self-tail-recursion
→ loop.

## Bench — tak converts hard, geomean 1.47× → 1.42×

`rm -rf build/fuzz_ad_codegen` first; `BENCH_NO_DOC=1 BENCH_REPS=9`, both `--opt`:

| kernel | BEFORE ON/C-O2 | AFTER ON/C-O2 |
|---|---|---|
| tak | 1.62× | **1.25×** |
| geomean (8 kernels) | 1.47× | **1.42×** |

Rigorous interleaved same-host A/B on the two `--opt` tak ELFs (best-of-40,
alternated per trial, both print checksum 36): **AFTER/BEFORE = 0.782** — a
**1.28× wall-time speedup** on tak from the tail-loop alone. tak is the
worst compute-bound kernel and its residual was entirely call overhead
(`docs/perf_p5_leamuladd_result.md` §1: "recursion call overhead … gcc turns the
3rd self-call into a loop"). This is that lever. All other kernels are unmoved
(tak is the only tail-recursive one), so the geomean move is entirely tak.

## Invariants

* **flag-OFF byte-identity** `scripts/test_native_vs_seed_objdiff.sh`: **307/307
  clean, 0 divergences, PASS** (units total 311, native-accepted 307). The
  transform is unreachable without `--opt`, so the default build — and the
  native compiler's own bootstrap (never `--opt`) — is byte-identical to the
  seed. Self-host is therefore unaffected.
* **differential fuzzer** `scripts/fuzz_adder_diff.sh`: **500/500, 0
  miscompiles** on seeds 1 and 2 (calling-convention stress).
* **new focused gate** `scripts/test_opt_tailcall.sh`: **35 cases, 0 fails** —
  self-tail-recursion of arity 1..6 with arguments that PERMUTE / cross-read the
  parameters (the parallel-move hazard), signed + unsigned, int32 sub-8-byte
  params, ON == OFF == Python reference; plus NON-firing shapes (non-tail
  `n*fact(n-1)`, mutual recursion `is_even`/`is_odd`, all correct) and a
  200000-deep tail recursion that runs under `--opt` without growing the stack
  (proves the frame is reused).
* all eight bench checksums AGREE (tak 36, collatz 103275238, mandel 6712881,
  saxpy 10116645105, sieve 1787196, licm 53068958052892,
  dcecopy 6400000000000000, matmul 1886692650); float paths untouched
  (movaps, not movsd).

## Honest geomean vs the ~1.3× scalar ceiling

**1.42× of gcc-O2** (from 1.47×), moving toward the documented **~1.3× honest
scalar ceiling** floored by the memory-bound array kernels (sieve/saxpy/matmul),
NOT by missing vectorization (`docs/perf_p5_leamuladd_result.md` §1). tak is now
1.25× — at its ~1.25 post-lever target from that doc's roadmap. Remaining
compute-bound levers: collatz signed `/2` range-analysis (`sar $1`), the
`and`/flag-consuming compare peephole, and extending the lea-muladd tile onto the
dest-driven `sel_*` path.
