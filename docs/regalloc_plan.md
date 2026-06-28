# Register allocation & the ≤2×-of-C goal — investigation + implementation plan

Status: RESEARCH + PLAN (no `codegen.ad` changes landed). Branch off `main`
HEAD 68fb1af7. Host-only, no QEMU.

This doc grounds the regalloc work in what the backend **actually does today**
(not the benchmark doc's hypothesis), reports a POC measurement that **revises
the diagnosis**, and lays out a phased plan that is honest about how close
register allocation alone gets to ≤2× of gcc -O2.

---

## TL;DR — the headline correction

The benchmark doc (`docs/bench_opt_results.md`) attributes the 7.1× gap to
"every local round-trips through memory" and names register allocation as the
lever. **Two of those premises are wrong, and the investigation changes the plan:**

1. **A linear-scan register allocator already exists and is already wired in and
   firing.** `adder/compiler/regalloc.ad` (478 lines, Poletto–Sarkar linear scan
   over `cfg.ad` live intervals) is enabled by `--opt` and promotes most hot
   scalars. On the benchmark kernels it puts 7/7 (matmul), 9/9 (sieve), 12/14
   (dcecopy) locals into callee-saved registers. It is **not** dead/seed code.
   So "add a register allocator" is largely already done — yet the benchmark
   still shows only ~1.05×.

2. **Register-residency of hot locals is NOT the bottleneck on this CPU.** A
   controlled POC (`docs/poc/regalloc/`, collatz pure-scalar inner loop, gcc -O0,
   `volatile` = memory vs plain = registers) measured **0.99×** — register
   residency bought essentially nothing, because stack slots are L1-hot and
   store-to-load forwarding makes the round-trips nearly free. The same kernel at
   gcc **-O2 is 2.7× faster**, and the difference is **strength reduction and
   instruction selection** (`n/2` and the `n - half*2` parity test become
   shift/and — gcc -O2 emits **zero `idiv`**; -O0 emits one `idiv` per inner
   iteration), not memory traffic.

**Consequence for the goal:** finishing/upgrading the register allocator will
NOT, by itself, reach ≤2× of -O2. The dominant gap is the absence of (a)
division-by-constant strength reduction, (b) general instruction selection
(LEA-based address arithmetic, `inc`, fused compare-branch), and (c) keeping
expression temporaries in registers instead of the push/pop stack machine. The
plan therefore treats regalloc as **one of three coordinated levers** and is
explicit about the expected contribution of each.

---

## 1. What the backend does today (evidence)

### 1.1 The default (non-`--opt`) path is a pure stack machine

`adder/compiler/codegen.ad` (8836 lines) walks the AST and emits x86-64 directly.
There is **no separate IR/SSA emit in the default path** — `ir.ad`/`cfg.ad` are
only consumed under `--opt`.

* **Local reads** — `gen_expr()` ND_IDENT case, `codegen.ad:4548-4577`. Every
  read of a scalar local emits `movq off(%rbp), %rax`
  (`emit_load_local_rax`, `codegen.ad:3374`). Sub-8-byte locals use sized
  signed/unsigned loads (`:4565`).
* **Local writes** — `store_to_named()`, `codegen.ad:7044-7084`. Every assignment
  emits `movq %rax, off(%rbp)` (`emit_store_local_rax`, `codegen.ad:3380`).
* **Stack-slot layout** — `alloc_local()` (`codegen.ad:867`) + the
  `prescan_block()` pre-pass (`codegen.ad:8204`) give **every** declared local an
  `%rbp`-relative slot unconditionally, before the prologue's `sub $frame,%rsp`.
* **Expression temporaries** — pure **right-push / left / pop-`%rcx`** stack
  machine. `a + b` emits: eval `b`→`%rax`, `push %rax`, eval `a`→`%rax`,
  `pop %rcx`, `add %rcx,%rax` (`gen_expr` binop, `codegen.ad:4698-4709`). Every
  binary-op intermediate round-trips through the runtime stack. **This is a
  second, untouched source of memory traffic that even the register allocator
  does not address** (regalloc only promotes named locals, not anonymous temps).

So the claim "every local round-trips through memory" is literally true of the
emitted code — but see §2: that traffic is mostly L1-forwarded and cheap.

### 1.2 The register allocator (`regalloc.ad`) — exists, wired, firing

* **Algorithm**: classic linear scan (Poletto–Sarkar). Collect promotable names
  with `[start,end)` intervals from `cfg.ad`, sort by start, walk with
  expire-old / assign-free / spill-furthest-end (`ra_linear_scan`,
  `regalloc.ad:245`).
* **Pool**: **callee-saved only** — `%rbx,%r12,%r13,%r14,%r15`
  (`ra_pool_init`, `regalloc.ad:119`; `RA_NREGS=5`). Deliberate: a callee-saved
  reg survives any `call` for free under System-V, so **call-crossing is correct
  with no save/restore at call sites** — the simplest correct call strategy.
  Caller-saved regs (`%rax,%rcx,%rdx,%rsi,%rdi,%r8–%r11`) are never touched, so
  the existing stack-machine lowering (which clobbers `%rax/%rcx`) is undisturbed.
* **Promotability** (`cfg.lr_is_promotable`, `cfg.ad:1369`): a name is promotable
  iff it has a live range AND is **not** in the clobber set `cl_set`
  (`cfg.ad:1210`). A name is clobberable if its address is taken (`&x`) or it is
  stored-through — those stay in memory. Array/aggregate locals are never
  promoted (only scalars).
* **Codegen integration** (the write-through scheme):
  * **Read** — `codegen.ad:4572-4577`: `renc = ra_reg_for_name(...)`; if a
    register was assigned, `emit_mov_callee_rax(renc)` and **return** (the memory
    load is skipped). Reads genuinely come from the register.
  * **Write** — `codegen.ad:7059-7062`: if assigned, `emit_mov_rax_callee(wenc)`
    **and then still** `emit_store_local_rax(off)`. **Writes are write-through:
    the memory store ALWAYS executes**, even for a promoted local.
  * **Sub-8-byte writes** bypass the register mirror entirely
    (`codegen.ad:7052-7053`) — sized stores go straight to memory.
* **Prologue/epilogue**: pushes/pops exactly the pool regs used
  (`codegen.ad:2236`, `:2303`), with alignment padding. Under `--opt` it also
  "borrows" dead callee-saved regs as IR scratch (`codegen.ad:3816`).
* **Gating**: `ra_enabled` defaults 0 (`regalloc.ad:94`); the dump driver calls
  `ra_enable()` only under `--opt` (`tests/fuzz/ad_codegen_dump_driver.ad:335`).
  With the flag off, `ra_reg_for_name` returns `RA_NONE` and codegen is
  **byte-identical** to the pre-regalloc path. The kernel/userland native build
  never passes `--opt`, so objdiff/kobjdiff stay clean.

**Measured promotion (this host, `run_regalloc` over the bench kernels):**

| kernel | promotable | in-reg | spilled | regs used | call-crossing |
|---|--:|--:|--:|--:|--:|
| matmul  | 7  | 7  | 0 | 5 | 5 |
| licm    | 9  | 7  | 2 | 5 | 3 |
| dcecopy | 14 | 12 | 2 | 5 | 4 |
| fib     | 6  | 6  | 0 | 4 | 2 |
| sieve   | 9  | 9  | 0 | 5 | 5 |
| collatz | 7  | 7  | 0 | 3 | 3 |
| mandel  | 18 | 9  | 9 | 5 | 5 |

The allocator works and saturates its 5-register pool. The limited end-to-end
win is therefore **not** an allocation failure.

### 1.3 IR / CFG substrate

* `cfg.ad` (1606 lines) builds, per function: a whole-function CFG, per-block
  liveness, value-level half-open live ranges (`lr_start/lr_end/lr_valid` over a
  stable linear instruction numbering), and an alias/clobber set (`cl_set`). It
  is explicitly a "construction, not analysis" handoff designed to feed an
  allocator — and it does.
* `ir.ad` (824 lines) is a real tree IR consumed by the Phase-5 IR-emit path
  (`ir_emit_enable`, armed under `--opt`) for signedness-invariant arithmetic
  subtrees. It is **not** a full SSA lowering of the whole function; the default
  emit is still AST-walking.
* There is enough substrate for liveness + linear scan (already used) and for a
  small SSA/value-numbering layer if needed, but **no global instruction-selection
  IR** exists.

### 1.4 What is missing (the real levers)

* `opt.ad` (2824 lines) is all **AST value optimization**: const-fold, CSE, LICM,
  DCE, const-branch-fold, copy-prop. **No strength reduction, no
  division-by-constant lowering, no instruction selection.**
* `peephole_x86.py` only does boolean→branch fusion and a store/reload peephole,
  and is a Python-side asset, not the native code path.
* So the native backend emits `idiv` for every `/` and `%` (including `/2`,
  `%2`), never uses LEA for `i*N+j` address arithmetic, and round-trips every
  expression temporary through the runtime stack.

---

## 2. The POC — register-residency is NOT the bottleneck

Files: `docs/poc/regalloc/` (throwaway C models; see that README). Method: take a
kernel's hot loop, build it two ways at **gcc -O0** so the only variable is
residency — `*_mem.c` marks every hot local `volatile` (forces a load+store per
access, modelling Adder's stack slots); `*_reg.c` removes `volatile` (gcc keeps
them in registers, modelling an ideal allocator). `*_o2` = gcc -O2 = the target.

**collatz (pure-scalar branchy integer loop, zero array traffic — the most
regalloc-favourable kernel), best-of-7, i7-8086K @ 4.0 GHz:**

| build | time | vs mem |
|---|--:|--:|
| `cz_mem` (locals in memory — models no-regalloc) | 0.382 s | 1.00× |
| `cz_reg` (locals in registers — models ideal regalloc) | 0.389 s | **0.99×** |
| `cz_o2`  (gcc -O2 — target) | 0.139 s | **2.75×** |

Checksums identical (`103275238`). Inner-loop instruction count: 49 (mem) → 40
(reg) → far fewer at -O2. **-O2 emits zero `idiv`; -O0 emits one `idiv`
per iteration.** (A second model, `poc_mem.c`/`poc_reg.c` for matmul, also showed
~1.0× — matmul's inner loop is bound on `A[]`/`B[]` array loads, which are not
promotable, so regalloc cannot help it either.)

**Interpretation.** On a modern OoO x86 core, an `%rbp`-relative local that stays
in L1 is served by store-to-load forwarding in ~0 effective extra latency, so
moving it to a register saves almost nothing in wall time. The 2.75× gap to -O2
is dominated by **what instructions run**, not **where the operands live**:
- the `idiv` (≈20–40 cycle latency) that strength reduction removes,
- LEA-fused address arithmetic vs separate `imul`/`add`,
- fused compare-and-branch and `inc`/`dec` vs load-modify-store sequences.

This is the honest, load-bearing finding: **the brief's premise that the lever is
register allocation is incorrect for this workload class.** Register allocation is
necessary infrastructure and unlocks the *other* optimizations (you can't do good
instruction selection while every value is pinned to a stack slot via a rigid
stack machine), but it is not where the ≤2× win comes from.

---

## 3. Plan

Because regalloc.ad already exists and already allocates well, the work is **not**
"build an allocator from scratch." It is two tracks:

* **Track A — make the existing allocation actually pay off** (cheap, the
  register-residency lever, but per the POC worth little alone).
* **Track B — the optimizations that actually close the gap to -O2**
  (strength reduction + instruction selection + temp-in-register), which *depend*
  on a working allocator to have registers to select into.

All work stays gated behind `--opt` / `ADDER_OPT=1`. Default build remains
byte-identical (verified by objdiff/kobjdiff). Correctness is verified by the
differential fuzzer (`tests/fuzz/ad_codegen_host.py`) and by re-running
`scripts/bench_opt.sh`.

### Phase 0 (BLOCKER, do first) — fix the `--opt` miscompile + harden the fuzzer

`docs/bench_opt_results.md` documents three `ADDER_OPT=1` miscompiles
(sieve/collatz/mandel) with a minimal nested-`while` reset-and-read repro
(expected 15, got 6). The fuzzer reports **0 miscompiles** because its corpus
never generates that control-flow shape. **No regalloc/codegen optimization may
land on top of a backend that miscompiles and a fuzzer that can't see it** —
register-allocation and instruction-selection bugs are the subtlest in any
compiler and the fuzzer is the only safety net.

* Root-cause the nested-loop reset-and-read defect. The bench doc localizes it to
  "the IR-emit/lowering path `--opt` enables" (none of the six AST passes fire on
  the repro), i.e. likely the Phase-5 IR-emit (`ir_emit_enable`) or a
  liveness/live-range error in `cfg.ad` that makes regalloc reuse a register
  whose previous owner is wrongly considered dead across the outer-loop back-edge.
  Given the shape (a local re-init'd at the top of each outer pass, read after the
  inner loop), a **live-range that doesn't extend across the outer back-edge** is
  the prime suspect — exactly the kind of bug linear scan turns into a clobber.
* Harden the fuzzer to generate nested loops with loop-carried + per-iteration
  re-initialized accumulators read after the inner loop, and assert no
  miscompiles, BEFORE any Phase 1+ work.
* Deliverable: fuzzer corpus extended, all three kernels correct under `--opt`,
  `bench_opt.sh` shows 0 miscompiles. **This is the gate for everything below.**

Expected speedup: none (correctness). Risk: this may itself be a regalloc live-
range bug, in which case the existing allocator is *unsafe* and Phase 1 starts by
fixing it, not extending it.

### Phase 1 — make register-resident writes real (Track A)

Today writes are **write-through**: every assignment to a promoted local still
emits the memory store (`codegen.ad:7062`). Eliminate the redundant store for a
promoted, non-address-taken scalar so a hot loop counter lives purely in its
register across the loop body (store back only at its last def before a point
that reads memory — but promoted scalars are never address-taken, so the only
memory readers are the sub-8-byte sized-load sites, which can be made to read the
register too). Also extend register write to the **sub-8-byte** path
(`codegen.ad:7052`), which currently bypasses the register entirely.

* Plug-in points: `store_to_named` (`codegen.ad:7044`), the ND_IDENT read
  (`codegen.ad:4548`), sized load/store helpers.
* Correctness: write-through is the *safe* default; dropping the store requires
  proving no memory reader of that slot exists in the live range. The clobber set
  already guarantees not-address-taken; the remaining memory readers are
  enumerable codegen sites. Conservative fallback = keep write-through (still
  correct, just slower) when unsure.
* **Expected speedup: small — ~1.0–1.1× per the POC.** Worth doing because it is
  cheap and is a prerequisite for Track B (you cannot keep a temp in `%rax` for an
  instruction-selected sequence while the surrounding stack machine insists on
  store-through), but on its own it does **not** move the ≤2× needle. Land it for
  the infrastructure, not the number.

### Phase 2 — division/modulo-by-constant strength reduction (Track B, BIGGEST WIN)

This is the single highest-value change the POC identified. Lower `x / C` and
`x % C` for constant `C` to shifts/AND (power-of-two) or the standard
multiply-high reciprocal sequence (general constant), eliminating the per-use
`idiv`. This is an `opt.ad` AST/IR transform plus codegen support for the
`mulx`/`imul`-high + shift sequence; it is gated by `--opt` and validated by the
fuzzer (division lowering is a classic miscompile source — exercise signed/
unsigned, negative dividends, `INT_MIN`, and `C` = 1/2/power-of-two/general).

* Plug-in: a new strength-reduction pass in `opt.ad` (rewrites the AST/IR node),
  with codegen emitting the reciprocal-multiply sequence; needs scratch registers
  — which the allocator/borrow machinery already provisions.
* **Expected speedup: large on div-heavy kernels.** collatz at -O2 is 2.75× over
  -O0 and removing `idiv` is the bulk of that; sieve/mandel also do per-iteration
  `/`/`%`. Estimate **~1.5–2.2×** on div-heavy kernels, ~1.0× on div-free ones.
* Risk: signed division rounding (truncation toward zero) makes the reciprocal
  sequence fiddly; **this is the correctness-critical pass** and the reason
  Phase 0 fuzzer hardening must precede it.

### Phase 3 — instruction selection: LEA address arithmetic + temps-in-registers (Track B)

* **LEA / address arithmetic**: lower `base[i*N + j]` and similar to LEA-fused
  forms instead of `imul`+`add`+separate load; use `inc`/`dec` for `+1`/`-1`
  loop steps; fuse compare-and-branch. This is what makes matmul's inner loop
  competitive (its `i*N+k` / `k*N+j` index math is the hot path).
* **Kill the temp stack machine**: stop round-tripping every binary-op
  intermediate through `push`/`pop` (`codegen.ad:4698`). Keep the left operand in
  a scratch register (the allocator's borrow pool already frees callee-saved regs;
  caller-saved `%rcx`/`%rdx` are available between sequence points). This removes
  a large fraction of the *non-local* memory traffic the allocator never touched.
* Plug-in: `gen_expr` binop lowering + a small instruction-selection layer over
  the existing IR. Gated, fuzzer-verified.
* **Expected speedup: moderate–large on array/index-heavy kernels** (matmul,
  sieve, dcecopy). Estimate **~1.3–1.8×** on those; combined with Phase 2 this is
  where the geomean approaches the target.

### Phase 4 (optional) — widen the register pool + caller-saved with call-aware spilling

Add `%rdx,%rsi,%rdi,%r8–%r11` (caller-saved) to the pool with proper
save/restore (or live-range splitting) around calls. Today's callee-saved-only
pool (5 regs) is correct but small; loop-heavy code with >5 hot scalars spills
(mandel: 9 spilled). Caller-saved regs are free inside leaf regions between
calls. Only worth it after Phases 1–3 show register pressure (not memory traffic)
is the residual limiter — per the POC, that is unlikely to be the binding
constraint, so **this is lowest priority**.

* Expected speedup: marginal except on register-pressure-bound leaf loops.

---

## 4. Honest estimate toward ≤2× of gcc -O2

Current: **7.1× slower** than -O2 (geomean). Target: **≤2×**.

| after | expected geomean vs -O2 | basis |
|---|--:|---|
| Phase 0 (correctness only) | ~7.1× (unchanged) | re-enables 3 excluded kernels honestly |
| Phase 1 (register writes) | ~6–7× | POC: residency ≈1.0×; infra, not speed |
| Phase 2 (div-by-const)    | ~3.5–5× | removes `idiv` on collatz/sieve/mandel (each ~2× there) |
| Phase 3 (LEA + temp regs) | ~2–3× | closes matmul/sieve/dcecopy index+temp traffic |
| Phase 4 (wider pool)      | ~2–2.8× | marginal, pressure-bound cases only |

**Bottom line, stated plainly:** register allocation alone (Phase 1, the thing the
brief asked to build) gets to roughly **6–7×**, i.e. it does NOT reach the goal —
the POC proves residency is nearly free on this CPU. **≤2× is reachable only by
also doing strength reduction (Phase 2) and instruction selection (Phase 3)**, and
even then the estimate lands at ~2–3× geomean; hitting ≤2× on *every* kernel is
optimistic for a hand-written single-pass backend and may require a real
instruction-selection IR (a larger rewrite than any single phase here). The
defensible commitment is: **Phases 2+3 bring the geomean from 7.1× into the
2–3× band**, with div-free / array-bound kernels likely the last holdouts above 2×.

The allocator should still be finished (Phase 1) because it is the substrate that
makes Phases 2–3 possible — but it should be sequenced and *sold* as enabling
infrastructure, not as the speed win.

---

## 5. Cross-cutting risks / invariants

* **Default build byte-identical.** Everything stays behind `--opt`; objdiff/
  kobjdiff must stay clean. Never let an optimization leak into the un-`--opt`ed
  native kernel/userland build.
* **Fuzzer is the only safety net** and currently has a blind spot (Phase 0). No
  optimization lands before the fuzzer can see the bug class it might introduce.
  Division lowering and register reuse across back-edges are the two highest-risk
  areas — generate corpus for both first.
* **Regalloc may already be unsafe.** The documented nested-loop miscompile could
  be a live-range-across-back-edge bug in `cfg.ad`/`regalloc.ad`. If so, Phase 0
  is a *fix to existing shipped-under-`--opt` behavior*, not just a fuzzer gap.
* **One allocator, one writer.** This is the correctness-critical pass; a single
  agent should own the codegen integration, on a hardened fuzzer, with bench +
  fuzzer green before each commit.
