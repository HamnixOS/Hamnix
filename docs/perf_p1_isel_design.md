# P1 — Destination-driven instruction selection: design & staging plan

**Status:** DESIGN / FEASIBILITY (host-only, no QEMU, no codegen changes landed).
Branch off `main` HEAD 6b9055dc. Decision-support for the user: greenlight the XL
instruction-selection rewrite, or stop at the exhausted non-XL frontier.

**Reading order:** this doc assumes `docs/perf_2x_roadmap.md` (gap anatomy, the
matmul disasm) and `docs/regalloc_plan.md` (regalloc substrate, the residency
POC). It does not repeat their measurements; it cites them.

---

## 0. Where the backend actually stands (grounded in `codegen.ad` today)

The session landed 10 verified `--opt` levers (7.14× → **4.30× of gcc -O2**).
Crucially, they did **not** leave the stack machine untouched — they built a
**partial expression IR** (`adder/compiler/ir.ad`) and a **single-accumulator IR
emitter** (`gen_expr_ir`, `codegen.ad:4980`) that already kills push/pop for
*some* expression shapes. Understanding exactly how far that goes is the whole
basis for scoping P1, because P1 is **not** a green-field build — it is the
**generalization** of `gen_expr_ir` from a one-target accumulator emitter into a
real destination-driven selector.

### 0.1 What exists

* **`ir.ad`** — a small tree IR: `IR_CONST`, `IR_IDENT` (named-local read),
  `IR_LEAF` (opaque AST-backed read: cast / `arr[i]` / field), `IR_BINOP` (pure
  binary op over two IR ids). `ir_lower_pure_expr(node)` (`ir.ad:634`) lifts a
  **side-effect-free** `ND_BINARY` subtree into this IR; anything impure,
  signedness-ambiguous, or out-of-set returns 0 → AST fallback. The IR arena is
  **reset per top-level expression** (`ir_reset()` in `try_gen_expr_ir`,
  `codegen.ad:5455`). **There is no whole-function IR and no CFG-level IR** —
  `cfg.ad` builds liveness/live-ranges over a *linear AST instruction numbering*
  for the linear-scan allocator, not an instruction IR.

* **`gen_expr_ir(v)`** (`codegen.ad:4980`) — the IR emitter. It is a
  **single-target recursive descent: every node lands its result in `%rax`.**
  There is **no `dst` parameter.** `IR_BINOP` evaluates LEFT into `%rax`, parks it
  in a **callee/caller-saved scratch register** (the `ir_scratch_*` pool,
  `codegen.ad:4539-4704`) instead of `push %rax`, evaluates RIGHT into `%rax`,
  then combines `op %scratch,%rax`. When the scratch pool is exhausted it **falls
  back to the exact `push %rax`/`pop %rcx` stack-machine sequence** for that node
  (always correct). The scratch pool draws from regalloc-unused callee-saved regs
  (always sound) plus, **only across a call-free tree**, caller-saved regs, plus a
  **borrow** path that lends a regalloc-held register when its promoted local is
  provably dead at the current program point (`ir_scratch_can_borrow`,
  `codegen.ad:4639`).

* **The landed levers are all special-cases inside the one `IR_BINOP` arm** of
  `gen_expr_ir` (`codegen.ad:5004-5260+`): constant-fold (`ir_tree_is_const`),
  ADD-constant reassociation, div/mod **strength reduction** (`gen_div_const`),
  **alu-load fold** (`op (%rcx),%rax` for an 8-byte integer `arr[i]` source,
  gated `isel_is_enabled()`), scaled-index `lea`, **load-CSE** (value-numbered
  `IR_BINOP`/`IR_LEAF`), and a separate `try_gen_fp_expr_ir` SSE arm. The
  **cmp+jcc** branch lever lives at the statement layer (`gen_if`/`gen_while`),
  not in `gen_expr_ir`.

### 0.2 The three structural limits that cap the current emitter

These are exactly why the frontier is exhausted and why the residual is "stack
machine," even though push/pop is partly gone:

1. **Single-target (`%rax`-anchored), not destination-driven.** Because every
   node must produce `%rax`, the emitter cannot say "compute this subtree
   *directly into* `%r13`" or "leave it as a memory operand `(%rcx)`." Operands
   are *parked* in scratch regs and *combined back into* `%rax` — that is push/pop
   replaced by `mov`, not eliminated. The matmul disasm
   (`docs/perf_2x_roadmap.md` §"Adder `--opt`") still shows `mov rcx,rax` / `mov
   rax,<reg>` shuffles precisely because the running value is pinned to `%rax`.

2. **Expression-rooted, re-entrancy-guarded — the glue is still the stack
   machine.** `try_gen_expr_ir` (`codegen.ad:5426`) only fires on a **top-level
   `ND_BINARY`**, and its **re-entrancy guard** (`ir_emit_in_progress`,
   `codegen.ad:5434`) forces *any nested* expression reached through an `IR_LEAF`
   delegation back onto the AST stack machine. So **address arithmetic inside an
   index, the loop-bound compare, the IV update, and `arr[i] = expr` store
   targets are NOT on the IR path** — they are emitted by `gen_expr`/`gen_index_addr`/
   `store_to_named` as the value-at-a-time stack machine. The 8-instruction loop
   test and the per-iteration array-base `lea [rip+...]` recompute in the matmul
   disasm are this: statement-level glue the IR never sees.

3. **No value-location model.** A value is either "in `%rax` right now" or "in a
   named local's stack slot / promoted reg" or "a parked scratch." There is no
   first-class notion of *where a computed value lives* that the selector can
   thread through a tree, which is the precondition for both destination-passing
   and for tiling a multi-node pattern (e.g. `base + i*8` → one `lea`) without
   re-deriving `%rax`.

**P1 is the removal of all three limits**: give the emitter a destination, extend
it past the expression root to cover statement glue, and introduce a value-location
abstraction so the landed levers become *tile patterns* rather than `%rax`-arm
special-cases.

---

## 1. Design: the destination-driven selector

### 1.1 Shape: destination-passing recursive descent first, DAG tiling only if measured

**Recommendation: a destination-driven recursive-descent selector with a small
fixed tile set — NOT a full maximal-munch BURS/DAG tiler in phase one.** Rationale:

* The gap anatomy (`docs/perf_2x_roadmap.md`) attributes ~3–3.5× of the 6× matmul
  factor to **operand plumbing** (push/pop, `%rax` round-trips, the 8-instr loop
  test) — i.e. to the *single-target* limit, not to missing *complex tile
  matches*. A destination-passing descent that keeps each subtree's result in its
  allocated register and emits 2-operand forms closes that plumbing factor
  directly. The already-landed levers (alu-load fold, scaled `lea`, strength
  reduction, cmp+jcc) are already the handful of multi-node tiles that matter;
  generalizing them is a small *fixed* tile set, not an open-ended grammar.
* A full DAG/maximal-munch tiler (cost-table dynamic programming over a tree
  grammar) is the right end-state for a production compiler, but it is a second
  XL on top of the first and buys little on *this* suite, where gcc itself isn't
  doing exotic selection — it's doing 2-operand scalar codegen with strength
  reduction and register-resident IVs. **Defer the DAG tiler; revisit only if,
  after dest-passing + statement-glue lowering, a kernel is still >2.5× and the
  disasm shows un-fused multi-node patterns (not plumbing) as the residual.**

So: **maximal-munch-*lite*** — a recursive-descent selector that, at each node,
*greedily matches the largest tile from a small fixed table* (the landed levers,
promoted to tiles) before falling back to the generic 2-operand emit. This is
strictly more powerful than today's `%rax` emitter and strictly less work than a
BURS generator.

### 1.2 The destination + value-location abstraction

Introduce a `Loc` (value location) descriptor that every selector entry threads:

```
Loc kinds:
  LOC_REG   enc            # value is (or must land) in x86 reg `enc`
  LOC_MEM   base,index,scale,disp   # an addressable memory operand (for fold/store dst)
  LOC_IMM   value          # a known constant (materialize lazily)
  LOC_NONE                 # caller doesn't care where; selector picks cheapest
```

The selector entry becomes `sel_expr(v: ir_id, dst: Loc)`:

* `dst = LOC_REG(r)` → compute the subtree **into register `r`**, choosing the
  2-operand form (`add r, src` / `imul r, src`) so the running value never leaves
  `r`. For `a OP b`: pick which operand becomes `r` (commutativity-aware, reusing
  the existing `ir_op_commutative`), recurse `sel_expr(left, LOC_REG(r))`, then
  emit `OP r, <loc-of-right>` where right is materialized as the cheapest of:
  an immediate (`LOC_IMM`), a memory source (`LOC_MEM`, the alu-load fold), or a
  register (recurse into a fresh allocated reg). **No park-and-restore: the
  destination IS the accumulator.**
* `dst = LOC_NONE` → return the `Loc` where the value naturally landed (e.g. a
  promoted local's register, an immediate) without forcing a move — this is what
  lets `s += a*b` add *into* the accumulator's home register, and what lets a
  leaf `arr[i]` stay a `LOC_MEM` to be folded by its parent.

The register operand of a subtree is drawn from the **existing linear-scan
allocator + the existing scratch/borrow pool** (`regalloc.ad`,
`ir_scratch_acquire`). The selector does **not** introduce a new allocator — it
reuses the live-range info `cfg.ad` already produces and the
acquire/release/borrow discipline already proven sound this session. A subtree
that needs a temp register calls `ir_scratch_acquire()`; LIFO release mirrors the
descent exactly as today.

### 1.3 How the landed levers become natural tile cases (not bolt-ons)

Each lever is re-expressed as a tile matched in `sel_expr` *before* the generic
2-operand emit. The logic already exists; P1 moves it from "`%rax`-arm special
case" to "tile keyed on `(op, child Locs)`":

| landed lever | tile in the dest-driven selector |
|---|---|
| **scaled-index `lea`** | `IR_BINOP(ADD, base, MUL(idx, {1,2,4,8}))` → emit `lea dst, [base + idx*scale + disp]`; folds a 3-node tree into one instr writing `dst` directly. Composes with the index-address path so `arr[i*N+j]` address math leaves the AST glue. |
| **alu-load fold** (`op (%rcx),%rax`) | right (or commutative-left) child is a `LOC_MEM` 8-byte int leaf → emit `OP dst, mem` with `dst` already holding the other operand. Becomes the natural "materialize right as `LOC_MEM` not `LOC_REG`" case — `ir_leaf_foldable_mem8` is reused verbatim. |
| **div/mod strength reduction** | `IR_BINOP(DIV/MOD, x, IMM C)` tile → `gen_div_const` into `dst`. Unchanged sequence; only the target generalizes from `%rax` to `dst`. |
| **ADD-const reassociation** | sum all `LOC_IMM` contributions of an ADD chain into one `add dst, imm32`. |
| **load-CSE** | value-numbered `IR_BINOP`/`IR_LEAF` returns the `Loc` of the prior materialization (a `LOC_REG`) instead of re-emitting — the value-location model makes CSE *return a Loc* rather than re-run the subtree. |
| **cmp+jcc** | with statement-glue lowering (§1.4) the compare root's parent is the branch; the tile is `IR_BINOP(cmp-op, a, b)` consumed by a `BR` → `cmp a,b; jcc` with **no** setcc/movzx materialization, generalizing the current statement-layer lever into the selector. |
| **IV strength-reduction / promotion, per-region caller-saved** | unchanged — these are regalloc/cfg properties the selector *consumes* (it allocates into the IVs' registers); they don't move. |

The point: today these are seven `if` arms that each re-derive "is my operand the
special shape, am I at `%rax`." Under the value-location model they are seven tile
patterns keyed on child `Loc`s, matched by one dispatch, all writing an arbitrary
`dst`. That is what "natural cases, not bolt-ons" means concretely.

### 1.4 Extending past the expression root: the statement-glue lift

The biggest *new* surface (and the biggest win beyond plumbing) is lowering the
glue the IR never sees today:

* **Loop test** — `gen_while`/`gen_for_range` (`codegen.ad:9022`,`:9126`) emit the
  condition through the AST stack machine (the 8-instr test). Route the condition
  `ND_BINARY` through `sel_expr` with the branch as its consumer (the cmp+jcc tile
  already exists at statement level — unify it). Keep the loop bound `N` in a
  register across the loop (a live-range the allocator already could hold; the
  reload is a stack-machine artifact, not an allocation failure — see
  `docs/perf_2x_roadmap.md` point 3).
* **Index address arithmetic** — `gen_index_addr` (`codegen.ad:6365`) must become a
  `sel_addr(node) -> Loc(LOC_MEM)` that returns a `[base+idx*scale+disp]` operand,
  hoisting the array-base `lea [rip+...]` to a loop-invariant register
  (`docs/perf_2x_roadmap.md` point 4) and folding into the consuming load/store/ALU.
* **Store target** — `store_to_named` / indexed-store (`codegen.ad:8157`) becomes
  `sel_expr(rhs, dst=LOC_MEM(addr))` for `arr[i] = expr`, computing the RHS and
  storing in the selected form, and `dst=LOC_REG(home)` for a promoted scalar
  (which also subsumes the landed store-through-elimination lever).

This is the part that requires retiring (per shape) the re-entrancy guard: the
selector must be allowed to recurse through index/store nodes instead of bouncing
to the AST emitter. That is the staged risk in §2.

### 1.5 IR representation that feeds it

Extend `ir.ad`, do **not** replace it:

* Add node kinds the selector needs as first-class (so glue can be lowered):
  `IR_ADDR` (an addressable `[base+idx*scale+disp]` form), `IR_LOAD`/`IR_STORE`
  (memory access with an `IR_ADDR` child), `IR_BR`/`IR_CMP` (branch consuming a
  compare). These let the loop test, index math, and stores enter the same tree.
* Keep `ir_lower_pure_expr`'s discipline of carrying each leaf's `ir_ast`
  back-pointer (`ir.ad:634`) — it is how signedness and "byte-identical leaf
  emit" are reproduced; the selector still delegates a genuinely opaque leaf to
  the AST emitter when it cannot do better, preserving the seed bytes.
* **Per-function arena, not per-expression.** Today `ir_reset()` per top-level
  expression is what *forces* the re-entrancy guard. To lower statement glue the
  arena must persist across a statement/loop body so address/compare/store nodes
  coexist. This is the one substrate change with teeth (arena sizing,
  value-numbering scope for CSE). It is bounded — `IR_MAX=65536` already — and is
  the enabling step, staged first in §2.

**Not needed for P1:** full SSA, phi nodes, a global value graph. The selector
operates per basic-block-ish region (a straight-line statement or loop body),
consuming the **whole-function liveness `cfg.ad` already computes**. SSA is a
later, separate investment if a DAG tiler or GVN is ever pursued.

---

## 2. Staging plan — each phase flag-OFF byte-identical, fuzzer-gateable

Every phase stays behind `--opt`/`ADDER_OPT=1`; default build is byte-identical to
the frozen Python seed (objdiff/kobjdiff clean — the native kernel/userland build
never passes `--opt`). Every phase ships **with a fallback to the existing path
for any shape it does not yet handle**, so partial coverage is always correct. The
differential fuzzer (`tests/fuzz/ad_codegen_host.py`, corpus
`build/fuzz_ad_codegen` — `rm -rf` before each verify) is the gate; each phase
names the new corpus it requires *before* it lands.

The selector is introduced **alongside** `gen_expr_ir`, not as a replacement: a
new `sel_expr(v, dst)` that, for shapes it does not yet cover, **calls the
existing `gen_expr_ir`/AST emitter**. Coverage expands class by class; the old
emitter is the fallback floor at every step and is only deleted (optionally) once
the selector strictly dominates it.

### Phase 0 — substrate: per-function IR arena + `Loc` plumbing (no new codegen)

* Make the IR arena persist across a statement region; introduce the `Loc`
  descriptor and a `sel_expr(v, dst)` that **today just wraps `gen_expr_ir`**
  (dst is ignored / always `%rax`). Net byte-identical: this is pure refactor +
  the value-location type, no emit change.
* Fuzzer: existing corpus must stay 0-miscompile (proves the refactor is inert).
* **Ship value: none (infrastructure). Risk: LOW.** This is the de-risking step
  the regalloc plan's Phase-0 spirit demands — land the substrate inert first.

### Phase 1 — FIRST routed class: the pure arithmetic expression tree, destination = its store target

**Route `scalar = <pure arith ND_BINARY>` first.** Why this class first:

* It is the **highest-frequency, lowest-glue** shape and the one the existing IR
  already lowers (`ir_lower_pure_expr` covers it), so the *only* new behavior is
  "compute into the destination register instead of `%rax` then store." That
  isolates the destination-passing mechanic from the statement-glue lift.
* It directly produces the **store-through accumulator** win (`s += a*b`,
  `docs/perf_2x_roadmap.md` matmul point 2) when the destination is a promoted
  scalar — `add home, src` with no `%rax` trip and no spill, the single biggest
  named cost after plumbing.
* It cannot miscompile control flow (no branches/loops introduced), so it is the
  safest place to validate the `Loc`/2-operand-form machinery against the oracle.

Selector handles: `LOC_REG` destinations, the generic 2-operand emit, and the
arithmetic tiles (alu-load fold, strength reduction, reassoc) re-expressed on
`dst`. Everything else → fallback.

* **Fuzzer corpus to add FIRST:** dense arithmetic trees with mixed
  signed/unsigned operands, every `BINOP`, deep nesting (scratch-pool exhaustion →
  fallback path), commutative-swap cases, and `dst`-aliases-an-operand cases
  (`x = x*a + b` where the destination register is also a source).
* **Expected:** matmul accumulator stops spilling; modest geomean move (the inner
  loop's plumbing is partly addressed, but the loop test/address glue remain).

### Phase 2 — index address arithmetic + loads as `LOC_MEM` (`sel_addr`)

Lower `arr[i*N+j]` reads through `sel_addr → LOC_MEM`, fold into the consuming ALU
op / load, and hoist the array-base into a loop-invariant register. Retire the
re-entrancy guard *for index subtrees only* (the selector now recurses through
`ND_INDEX` instead of bouncing to AST).

* **Corpus:** multi-dimensional index math, negative/zero indices, mixed element
  sizes (1/2/4/8 — only 8-byte folds, others must fall back exactly), `arr[f()]`
  (impure index → must fall back, since address has a side effect), pointer vs
  array bases.
* **Expected:** removes the per-iteration `lea [rip+...]` base recompute and the
  separate index load; matmul inner loop approaches gcc's 2-loads form.

### Phase 3 — statement glue: loop test (cmp+jcc) + indexed store target

Route loop/branch conditions and `arr[i] = expr` stores through the selector,
keeping the loop bound register-resident, unifying the cmp+jcc lever, eliminating
the 8-instruction boolean test.

* **Corpus:** nested loops with loop-carried + per-iteration re-initialized
  accumulators read after the inner loop (the exact shape `docs/regalloc_plan.md`
  Phase-0 flags as the historical blind spot — generate it explicitly), all
  compare ops signed+unsigned, short-circuit `&&`/`||` (must stay correct — these
  are NOT pure and must fall back unless explicitly modeled), store-to-aliased-load
  within an iteration.
* **Expected:** matmul inner loop from ~33 → ~10 instr/iter (the
  `docs/perf_2x_roadmap.md` target); this is where the bulk of the geomean move lands.

### Phase 4 — coverage expansion + (optional) old-emitter retirement

Expand the routed classes (more leaf shapes, more ops, float trees via the
existing SSE arm), widen the register pool if Phase-3 disasm shows
register-*pressure* (not plumbing) as the residual (the regalloc plan's Phase-4,
likely marginal per its POC). Optionally delete `gen_expr_ir`'s `%rax` arm once
the selector strictly dominates it on the corpus — **only** if it simplifies
maintenance; keeping it as a proven fallback is also acceptable.

### Phase 5 (CONDITIONAL) — DAG/maximal-munch tiler

Only if, after Phases 1–4, a kernel sits >2.5× **and** its disasm shows
un-fused multi-node patterns (not plumbing, not spills) as the cause. Otherwise
**do not build it** — it is a second XL with no measured payoff on this suite.

---

## 3. Risk analysis — the byte-exact-to-seed + 0-miscompile bar

The default (no-`--opt`) build stays byte-identical by construction (the selector
is unreachable without the flag). The risk is entirely in the `--opt` correctness
lane: the selector must compute the **same value** as the seed for every input.
The differential fuzzer is the only safety net; each risk below names the corpus
that must exist *before* the phase that introduces it.

| risk | how it breaks byte/value equivalence | mitigation + required corpus |
|---|---|---|
| **Evaluation order** | The seed's stack machine is right-then-left; a dest-driven selector may evaluate left-then-right or pick a commutative swap. For **pure** subtrees this is value-equivalent (and the IR only lowers pure subtrees). The hazard is at the **pure/impure boundary**: if any leaf has a side effect (`f()`, a store), reordering changes results. | The IR already refuses impure subtrees (`ir_lower_pure_expr` → 0). The selector must inherit that gate **and re-check at every newly-routed node class** (index with `arr[f()]`, store RHS with a call). Corpus: every routed shape with an embedded call / store / volatile, asserting fallback + value-match. |
| **Signed vs unsigned** | Compares, DIV/MOD, SHR depend on operand signedness, which the seed reads from the *immediate operand AST nodes* (`expr_signedness`). A selector that synthesizes a node loses the `ir_ast` back-pointer and picks the wrong `idiv`/`div`, `sar`/`shr`, `setl`/`setb`. | Keep every IR leaf's `ir_ast` back-pointer (already done); derive `l_sgn/r_sgn` exactly as `gen_expr_ir` does today (`codegen.ad:5054`). Corpus: all compare/div/mod/shift ops × {signed, unsigned, mixed}, INT_MIN dividend, negative operands. |
| **Spills / scratch exhaustion** | A dest-driven tree deeper than the scratch pool, or one where `dst` aliases a live operand, can clobber a value if the fallback isn't taken. | The acquire/release/**borrow** discipline is already proven sound this session; extend its invariant (a scratch never aliases a live local; borrow only when provably dead via `lr_name_dead_after`). When acquire returns `RA_NONE`, fall back to the push/pop path for that node — never proceed without a home. Corpus: trees nested past the 10-reg pool; `x = x OP y` dst-aliasing; high-pressure functions (mandel: 9 spills today). |
| **ABI / call clobbers** | A caller-saved scratch held across a tree that turns out to emit a call gets clobbered. | The existing `ir_tree_has_call` gate (caller-saved scratch only across a call-free tree) carries forward unchanged; the **per-region caller-saved** lever's call-span analysis bounds it. Corpus: `buf[f()]`, `a*g() + b`, calls inside loop bodies that also use caller-saved scratch. |
| **Float / SSE** | The selector must not lower a float arith/compare through the integer 2-operand path. | The existing `ir_subtree_has_float` guard routes float roots to `try_gen_fp_expr_ir`; keep it as a hard pre-gate before any integer tile. Corpus: float arith/compare, int↔float mixed expressions, float `arr[i]` (must NOT alu-load-fold — it's SSE). |
| **Re-entrancy / arena scope (NEW in P1)** | Per-function arena + retiring the re-entrancy guard means a mid-walk `ir_reset` or a stale value-number could corrupt an in-progress tree or return a CSE `Loc` whose register was reused. | Stage the guard retirement **per node class** (Phase 2 index, Phase 3 store/branch), never wholesale; scope CSE value-numbering to a region with explicit clobber invalidation (the `cl_set`/`ir_clobbered` machinery already exists, `ir.ad:526`). Corpus: the nested-loop reset-and-read shape (the documented historical miscompile, `docs/regalloc_plan.md` Phase-0); CSE across a store that aliases the cached load. |

**Process invariants (carry forward from the session's discipline):**
`rm -rf build/fuzz_ad_codegen` before every verify; bench + fuzzer green before
every commit; one agent owns the selector (it is the correctness-critical pass);
each phase lands its **new corpus first**, proves it catches the bug class it
could introduce (deliberately break the emit, confirm the fuzzer fails), then
lands the optimization. No optimization lands on a fuzzer that can't see its bug
class — this is the lesson `docs/regalloc_plan.md` Phase-0 encodes.

---

## 4. Effort & payoff — honest verdict

### Effort

Roughly **5 phases ≈ 5–7 focused agent-runs**, single-owner, sequential (this is
one correctness-critical pass — it cannot be parallelized across agents without
fragmenting the selector):

* Phase 0 (substrate, inert): ~1 run.
* Phase 1 (first routed class, dest-passing arith): ~1–2 runs — the mechanic is
  new; most of the validation cost lives here.
* Phase 2 (index/load `LOC_MEM`): ~1 run (reuses `ir_leaf_foldable_mem8`,
  `gen_index_addr`).
* Phase 3 (statement glue: loop test + store): ~1–2 runs — the re-entrancy-guard
  retirement and nested-loop corpus make this the second-riskiest after Phase 1.
* Phase 4 (coverage + optional retirement): ~1 run.
* Phase 5 (DAG tiler): **conditional, excluded from the estimate** — only if
  measurement demands it (another XL, ~3–5 runs).

This is genuinely **XL**, but materially smaller than a green-field selector
because the IR, the scratch/borrow allocator, liveness, the signedness machinery,
and 7 of the tile patterns **already exist** — P1 is generalization + a glue lift,
not new infrastructure.

### Payoff — what closes, and the floor

The gap anatomy (`docs/perf_2x_roadmap.md`) attributes the matmul 5.98× as:
~3–3.5× **operand plumbing** (the dest-driven selector's direct target), ~1.4×
**non-resident accumulator/bound/base** (Phase 1 + Phase 2/3 keep them in regs),
~1.15× **DCE/copy-prop** (already partly landed), ~1.0× vectorization (gcc doesn't
vectorize these — **not on the path**).

* **Plumbing (~3×) collapses** with dest-passing + statement-glue lowering: matmul
  ~33 → ~10 instr/iter (the doc's own target), licm/dcecopy similarly. That alone
  takes the geomean from **4.30× toward ~2–2.5×**.
* **≤2.5× is the defensible commitment.** Phases 1–3 land the plumbing + residency
  wins; the geomean realistically reaches the **~2–2.5× band**.
* **≤2× is reachable on this specific suite but is the optimistic edge.** It is
  *possible without SIMD* — gcc doesn't vectorize matmul/licm/dcecopy, so a clean
  scalar 2-operand selector with register-resident IVs can in principle match it
  to within ~2× — but hitting ≤2× on **every** kernel (not just geomean) is the
  stretch; array-bound (saxpy 3.50×, bandwidth-capped) and the last compute-bound
  holdouts are the likely >2× stragglers. Promising ≤2.5× geomean and "≤2× on the
  compute-bound kernels where plumbing dominated" is the honest claim; promising a
  uniform ≤2× is not.

### The floor WITHOUT P1

**4.30× is the floor.** The non-XL frontier is exhausted: the residual is the
single-target/`%rax`-anchored/expression-rooted structure of `gen_expr_ir`, and no
further pass-based lever can express destination-passing or lower the statement
glue — those *are* the stack machine. The regalloc-residency POC
(`docs/regalloc_plan.md` §2) independently proves more allocation work alone buys
~1.0× on this CPU (store-to-load forwarding makes stack slots cheap), and the gap
anatomy proves a vectorizer buys ~0× here. **So: stay at ~4.3×, or commit to P1.
There is no cheaper path below ~4×.**

### Recommendation

**Greenlight P1, staged as above, Phase 0 substrate first.** It is the only lever
left that addresses the ~3× plumbing factor that *is* the gap; it reuses the
session's existing IR/allocator/tiles rather than rebuilding them; it is
incrementally shippable with a fallback floor and a fuzzer gate at every step; and
it is the difference between "4.3× and stuck" and "~2–2.5× geomean, ≤2× on the
compute-bound kernels." Skip the DAG tiler (Phase 5) unless post-Phase-3
measurement specifically demands it.
