# Adder SSA optimizer — architecture blueprint for the LLVM-shaped rewrite

Status: **DESIGN / CONTRACT** (no compiler changes landed by this doc). Branch off
`origin/main` @ `c148e38f`. Host-only bring-up, no QEMU, until Phase 4.

This document is the contract the implementation agents follow. It (1) grounds the
new design in what the current compiler *actually does*, file:line; (2) specifies
an LLVM-subset SSA pipeline reimplemented **in Adder** (never the LLVM C++ lib —
self-hosting is non-negotiable); and (3) decomposes the work into four
independently-testable phases the orchestrator can dispatch one at a time.

Non-negotiables carried from the memory index and the current tree:
- **Self-hosting.** The optimizer is Adder, compiled by `codegen.ad`, running
  on-device. No external codegen library.
- **Keep the hand-written x86_64 encoder.** `codegen.ad`'s `emit_*` byte
  emitters are good and stay. The new pipeline produces a machine-IR that drives
  those same emitters.
- **-O0 ships the OS throughout.** The new pipeline is built ALONGSIDE the
  current one behind a new gate (`ADDER_OPT2`); the default (no-flag) path stays
  byte-for-byte identical until the cutover criteria are met.
- **The differential fuzzer is the correctness oracle.** `scripts/fuzz_adder_diff.sh`
  (500 programs vs the Python backend + by-construction oracle) must stay green.

---

## 0. Why rewrite — the root cause

The current optimizer is a **non-SSA, name-based** IR spread across three files
with three different granularities, plus a large set of codegen special-cases
that consume it. The recurring miscompile class (loop-condition CSE hang,
dead-store global-cap bug, and the **systemic register-allocator miscompile that
blanks the kernel desktop**) all trace to the same structural weakness: *the IR
reasons about variable NAMES and their storage, not about SSA VALUES.*

Three concrete symptoms of the name-based design:

1. **Liveness is name-level, not value-level.** `cfg.ad` builds per-*name*
   def/use sets (`ci_def`/`ci_use`, `cfg.ad:197-199`) and per-name live intervals
   (`lr_start`/`lr_end`, `cfg.ad:1250-1252`). A name reassigned across two
   disjoint uses is ONE interval, not two values. The allocator
   (`ra_reg_for_name(off,len)`, `regalloc.ad:1042`) then maps a *string* to a
   register. Every downstream correctness question — "is this register free
   here?", "is this store dead?" — is answered by name-and-textual-position
   reasoning (`lr_name_dead_after_sameblock`, `cfg.ad:1924`; the borrow guard
   `ra_pool_all_dead_after`, `regalloc.ad:1131`), which is only sound *within one
   basic block* and is patched with a thicket of same-block guards. Cross-block
   name liveness with loop back-edges is exactly where the "loop-carried
   accumulator" miscompile lives (called out verbatim at `cfg.ad:1919`).

2. **Alias analysis is all-or-nothing per name.** `cl_build` (`cfg.ad:1790`)
   marks a whole name non-promotable if its address is ever taken or it is stored
   through a non-ident lvalue (`cfg.ad:1607-1619`). There is no per-load/store
   memory SSA, so CSE/LICM of memory operands is either refused
   (`ir_tree_has_leaf`, `ir.ad:342`) or hand-guarded per pass.

3. **The IR never has a whole-function value view.** `ir.ad` models only
   per-expression trees (`IR_CONST`/`IR_BINOP`/`IR_IDENT`/`IR_LEAF`,
   `ir.ad:91-101`); `cfg.ad` has the CFG but only name-level instructions. No
   pass can see "this value, defined here, used there, across these blocks" — the
   single fact every LLVM pass is built on.

The benchmark (`docs/bench_opt_results.md`) shows the register allocator is
~**96%** of the `--opt` speedup (full `--opt` = 4.20× O0 = 1.41× gcc-O2;
AST-passes-only = 1.14×). So the allocator is simultaneously the highest-value
and the most-broken component, and it sits on the shakiest part of the IR.
(`docs/regalloc_plan.md` adds an honest nuance: on the measured CPU, strength
reduction and instruction selection contribute materially too; the SSA rewrite
must not regress those levers — §5.)

**The fix is structural:** a typed SSA IR with φ-nodes, dominance, precise
value-level liveness, and a real machine-IR + allocator built on it — LLVM's
shape, reimplemented as a pragmatic subset in Adder.

---

## 1. The current pipeline (integration/cutover surface)

```
source
  └─ lexer.ad ──> parser.ad ──> AST arena (nd_kind/nd_a/nd_b/nd_c/nd_d/nd_next, parser.ad)
                                   │
             ┌─────────────────────┴──────────────── opt_enabled? (default 0) ──── no ──┐
             │ yes (--opt / ADDER_OPT=1)                                                 │
             ▼                                                                           ▼
   opt.ad: opt_run(prog)  ── 10 AST passes, REWRITE nd_* in place ──┐          (AST unchanged)
     rec2iter, constfold, constbranch, xcse, cse, licm, ivsr,       │                    │
     copyprop, paritymod, dce   (opt.ad:1385)                       │                    │
             │                                                       ▼                    ▼
             └──────────────────────────────> codegen.ad: gen_function(fn) (codegen.ad:17686)
                                                 AST walker + %rax/%rcx/%rdx stack machine
                                                 ├─ regalloc.ad (ra_*, keyed by NAME) ── under --opt
                                                 ├─ ir.ad IR-emit (gen_expr_ir) ──────── under --opt
                                                 └─ emit_* byte encoder ─────────────────> code_buf
                                                                                             │
                                              elf_emit.ad: elf_emit_image* ──────────────────┘
```

### 1.1 Data structures, by file

**`adder/compiler/ir.ad` (984 lines)** — per-expression value IR.
- Parallel global arrays, index = value id, 0 = null: `ir_kind`, `ir_op`,
  `ir_a`, `ir_b`, `ir_const`, `ir_ast` (back-pointer to the AST node),
  `ir_name_off`/`ir_name_len` (`ir.ad:105-116`). `IR_MAX = 65536` (`ir.ad:103`).
- Kinds: `IR_CONST`, `IR_BINOP`, `IR_IDENT`, `IR_LEAF` (opaque AST-backed read)
  (`ir.ad:91-101`). No φ, no blocks, no memory model.
- Value numbering is **structural equality** (`ir_value_eq`, `ir.ad:608`;
  `ir_ast_eq`, `ir.ad:484`) — hash-free, O(tree). Clobber checks are
  name-string scans (`ir_uses_name`, `ir.ad:642`).
- Consumed two ways: as an *analysis annotation* by opt.ad passes, and as an
  *emit source* by `gen_expr_ir` (`codegen.ad:6554`) for pure subtrees.

**`adder/compiler/cfg.ad` (2134 lines)** — whole-function CFG + liveness +
intervals + alias. This is the analysis substrate the allocator consumes.
- Name interning: `nm_intern(off,len)` → dense id (`cfg.ad:155`); `NM_MAX = 256`
  distinct names/function.
- CFG instructions (name-level): `ci_def[]` (one name defined), `ci_use[]`
  (≤`CI_MAX_USE=16` names used), `ci_has_call[]`, `ci_loopdepth[]`
  (`cfg.ad:197-273`). `ci_node[]` maps a ci back to its AST statement
  (`cfg.ad:311`).
- Basic blocks: `bb_first`/`bb_ninstr`/`bb_term`/`bb_succ0`/`bb_succ1`
  (`cfg.ad:377-384`); `BB_MAX = 8192`; terminator kinds `BBT_*` (`cfg.ad:370`).
  Built by `cfg_build_function(fn)` (`cfg.ad:924`) covering if/elif/else,
  while/do-while, for/for-unpack, break/continue.
- Liveness: bitset dataflow `lv_use/lv_def/lv_in/lv_out` (`cfg.ad:974-977`,
  `LV_WORDS=8`), `lv_solve()` fixpoint (`cfg.ad:1090`).
- Value(name)-level intervals: `lr_start`/`lr_end`/`lr_valid` half-open, over a
  linear ci numbering (`cfg.ad:1250`; `lr_build`, `cfg.ad:1289`). Plus idle-gap
  ("live-range hole") analysis `lr_build_holes` (`cfg.ad:1432`) with per-hole
  hotness — already the input a splitting allocator wants.
- Alias/clobber: `cl_build(fn)` (`cfg.ad:1790`) → `cl_set[]`; spill cost
  `nm_usecost[]` loop-depth-weighted (`cfg.ad:244`); `lr_is_promotable`
  (`cfg.ad:1823`) = has range ∧ not clobberable ∧ not truncated.
- Self-validator `cfg_validate` (`cfg.ad:1189`) + `lr_validate`/
  `lr_validate_holes` — the fuzzer runs these as a non-codegen lane.

**`adder/compiler/regalloc.ad` (1250 lines)** — linear scan, keyed by name.
- Poletto–Sarkar linear scan: `ra_collect_sorted` (`regalloc.ad:609`, by
  `lr_start`), `ra_linear_scan` (`regalloc.ad:709`), `ra_expire`
  (`regalloc.ad:692`). Spill by loop-weighted cost `ra_cheapest_active`
  (`regalloc.ad:665`) — evict the cheapest active value, keep hot accumulators.
- Pool: 5 callee-saved base (`%rbx,%r12–%r15`) + 5 caller-saved extension
  (`%rdi,%r8–%r11`) usable only for call-free-lifetime values, gated per-value by
  `lr_spans_call` (`regalloc.ad:637`, `ra_pool_cap_for`). XMM home class
  (`xmm8–15`) for float64 locals (`ra_xmm_scan`, `regalloc.ad:948`).
- Codegen queries, all **by name string**: `ra_reg_for_name` (`regalloc.ad:1042`),
  `ra_store_elim_for_name` (`regalloc.ad:1059`), `ra_xmm_for_name`
  (`regalloc.ad:1003`), `ra_pool_used` (`regalloc.ad:1103`),
  `ra_pool_all_dead_after` (`regalloc.ad:1131`).
- Correctness model: **write-through** — a promoted value's stack slot stays
  authoritative unless `lr_is_store_elim` proves no slot-bypass reader
  (`cfg.ad:1843`). This is the crutch that makes name-based allocation *almost*
  sound and is the source of the special-case sprawl.

**`adder/compiler/codegen.ad` (18357 lines)** — AST→machine stack machine.
- `gen_function(fn)` (`codegen.ad:17686`) orchestrates per function:
  `prescan_block` (slot layout) → `ra_build_cfg(fn)` → `cg_veto_nonlocal_names()`
  → `cg_mark_float_xmm` → `ra_build_scan()` → set `cg_ra_active`
  (`codegen.ad:17812-17821`) → prologue saves (`ra_emit_prologue_saves`,
  `codegen.ad:3144`) → body → epilogue (`emit_function_epilogue`,
  `codegen.ad:3334`).
- Callee-saved save/restore is derived from the **authoritative assignment
  table**: `cg_pool_saved` (`codegen.ad:3104`) → `ra_pool_used`
  (`regalloc.ad:1103`), deliberately *not* a parallel mask, to prevent the
  save-set from desyncing from the body (the method-prologue-corruption class the
  comment at `regalloc.ad:1088` describes).
- **General reg-reg encoder primitives already exist** and take arbitrary x86
  encodings 0..15 — this is the machine-IR → encoder interface the new backend
  reuses verbatim:
  - `emit_mov_reg_reg(src,dst)` (`codegen.ad:4244`)
  - `emit_alu_reg_reg(op,src,dst)` ADD/SUB/MUL/AND/OR/XOR (`codegen.ad:4253`)
  - `emit_alu_imm_reg(op,imm,dst)` (`codegen.ad:4327`)
  - `emit_alu_mem_reg(op,base,dst)` (`codegen.ad:4369`)
  - `emit_cmp_reg_reg(l,r)` (`codegen.ad:4412`)
  - `emit_lea_base_index_reg(base,idx,sbits)` (`codegen.ad:5198`)
  - `emit_imul_imm_reg(dst,src,imm)` (`codegen.ad:...`), `emit_load_local_callee`/
    `emit_store_local_callee(enc,off)` (`codegen.ad:3033`/`3049`),
    `emit_push_callee`/`emit_pop_callee(enc)` (`codegen.ad:2979`/`2988`).
  - REX/ModRM builders: `ir_rex_src_dst` (`codegen.ad:4229`),
    `ir_modrm_src_dst` (`codegen.ad:4239`).

**`adder/compiler/elf_emit.ad` (915 lines)** — wraps `code_buf` into an ELF
image: `elf_emit_image` (`elf_emit.ad:692`), `_target` (`:203`), `_kernel`
(`:352`). Unchanged by this work.

### 1.2 Gating machinery (what "off by default" means today)

- `opt_enabled` (`opt.ad:116`), `ra_enabled` (`regalloc.ad:120`),
  `ir_emit_enabled` (`ir.ad:831`) all default 0. The host driver
  (`fused_driver_host_main.ad:1285-1319`) arms them under `--opt`.
- `ADDER_OPT_DISABLE=<comma,list>` → `opt_disabled_mask` (`opt.ad:247`
  `opt_disable_bit_for`) — 16 levers: `rec2iter, constfold, constbranch, xcse,
  cse, licm, ivsr, copyprop, paritymod, dce` (AST) + `regalloc, iremit,
  strengthreduce, isel, vec, cmpjcc` (codegen). All 16 disabled ⇒ `--opt` ==
  -O0 byte-identical. Parsed by `opt_parse_disable_env` (`opt.ad:318`) +
  `ra_parse_env` (`regalloc.ad:344`).
- The kernel/OS build **never passes `--opt`**, so today the OS ships on the
  pure -O0 path. The new pipeline preserves this exactly.

### 1.3 The correctness harness the new pipeline must satisfy

- `scripts/fuzz_adder_diff.sh` — 500 fuzzer programs; the codegen.ad pipeline
  runs host-only via `tests/fuzz/ad_codegen_dump_driver.ad` (dumps raw bytes),
  wrapped into an ELF by `tests/fuzz/ad_codegen_host.py`, executed, compared to
  the by-construction oracle. Exits nonzero only on a genuine miscompile.
  Reproduce a failure with `--repro <seed>`.
- The CFG/liveness self-validators (`cfg_validate`, `lr_validate*`) run as a
  non-codegen fuzzer lane; the new SSA verifier joins them.
- Acceptance is NOT green host gates — it is the **shipped OVMF image booting and
  the desktop rendering** (memory: host-gate-green ≠ device-working).

---

## 2. The SSA IR (spec)

A new module **`adder/compiler/ssa.ad`**, in the parallel-global-array style of
`ir.ad`/`cfg.ad`/the AST arena (no dynamic allocation; fixed arenas sized like
the existing ones; per-function reset). It coexists with `nd_*` and `ir.ad`
during the alongside phase and does not touch them.

### 2.1 Why new arenas, not the `nd_*` tables

The AST must stay intact and unmutated during the alongside/gated phase so the
default -O0 path is byte-identical and so a differential can compare O0 vs OPT2
on the *same* AST. `opt.ad` mutates `nd_*` in place — the new pipeline must not.
So SSA gets its own arenas; the only cross-reference is a back-pointer
`sv_ast[]` (value → originating AST node) exactly like `ir_ast[]` (`ir.ad:110`),
used for diagnostics and for lowering leaves we choose not to model.

### 2.2 Value / instruction model

One flat arena, index = **value id** (`vid`), 0 = null/undef. A value IS its
defining instruction (LLVM style — no separate instruction table).

```
sv_op    : Array[N, uint32]   # opcode (SVO_*)
sv_type  : Array[N, uint32]   # type id (see 2.4)
sv_a     : Array[N, uint32]   # operand vid 0 (or immediate lo for consts)
sv_b     : Array[N, uint32]   # operand vid 1
sv_c     : Array[N, uint32]   # operand vid 2 (calls: extra-arg list head; GEP index)
sv_aux   : Array[N, uint32]   # opcode-specific: BINOP_* code, cmp predicate,
                              #   call arg count, field offset, mem size (1/2/4/8)
sv_imm   : Array[N, uint64]   # SVO_CONST value; global/symbol ref for addresses
sv_block : Array[N, uint32]   # the basic block this value belongs to (bid)
sv_ast   : Array[N, uint32]   # AST back-pointer (diagnostics / leaf re-emit)
```

Multi-operand instructions (calls, φ with >2 preds) hang a **use-list** off a
side arena `sv_arg[]` (flat, `sv_arg_head`/`sv_arg_n` per value) — the same trick
`ci_use` uses (`cfg.ad:198`), but storing vids not name ids.

**Opcode set (SVO_*) — the LLVM subset:**

| category | opcodes | notes |
|---|---|---|
| constants | `SVO_CONST` (int/bool/char in `sv_imm`), `SVO_FCONST` (float bits), `SVO_UNDEF` | |
| arithmetic | `SVO_BINOP` (`sv_aux` = existing `BINOP_*`), `SVO_NEG`, `SVO_NOT` | integer + the SSE float set reuse `BINOP_*` and the existing float classification (`ir_op_is_float_emittable`, `ir.ad:277`) |
| compare | `SVO_ICMP`, `SVO_FCMP` (`sv_aux` = predicate) | separate from BINOP so cmp/jcc fusion (§5) keys off it |
| convert | `SVO_TRUNC`, `SVO_ZEXT`, `SVO_SEXT`, `SVO_BITCAST`, `SVO_I2F`, `SVO_F2I` | one per `cast[T]` shape; width in `sv_type` |
| memory | `SVO_ALLOCA` (address-taken local slot), `SVO_LOAD`, `SVO_STORE`, `SVO_GEP` (base + scaled index + disp — maps to `emit_lea_base_index_reg`, `codegen.ad:5198`) | see 2.5 |
| control (terminators) | `SVO_BR` (uncond, `sv_a`=target bid), `SVO_CONDBR` (`sv_a`=cond vid, `sv_aux`/`sv_b` = then/else bid), `SVO_RET` (`sv_a`=value vid or 0) | one per block, last |
| φ | `SVO_PHI` — operands are (pred bid, incoming vid) pairs in the use-list | |
| calls | `SVO_CALL` (`sv_imm`=callee symbol or `sv_a`=indirect target vid; args in use-list), `SVO_SYSCALL` | clobbers per ABI (§4.4) |
| globals/percpu | `SVO_GLOBALADDR` (RIP-relative symbol in `sv_imm`), `SVO_PERCPU` (`%gs`-relative offset in `sv_imm`) | kept as first-class ops so §4.5's percpu-survives-allocation rule is structural |

This is deliberately a *subset*: no vectors as SSA values (the SSE
auto-vectorizer, `vec` lever, stays an AST/codegen pass — §5), no exceptions, no
indirectbr. Anything outside the subset is handled by the **escape hatch**
(§2.6).

### 2.3 Basic blocks & CFG

```
sb_first_val : Array[B, uint32]   # first value in the block (0 if empty)
sb_last_val  : Array[B, uint32]   # terminator value
sb_term      : Array[B, uint32]   # SVO_BR/CONDBR/RET (redundant w/ last, kept for validate)
sb_npred     : Array[B, uint32]   # predecessor count
sb_pred      : side arena         # flat predecessor lists (bids)
sb_idom      : Array[B, uint32]   # immediate dominator bid (computed, §3.1)
sb_loopdepth : Array[B, uint32]   # for spill weighting (reuse cfg's notion)
```

Values within a block form an intrusive doubly-linked list (`sv_next`/`sv_prev`)
so passes can insert/delete in O(1) — SSA passes need cheap instruction surgery
that the AST-rewrite model made painful. Block order is reverse-postorder (RPO),
computed once, so a forward dataflow pass is a single array walk.

The CFG shape is lowered from the same statement forms `cfg_build_function`
already handles (`cfg.ad:924`, if/elif/else/while/do-while/for/break/continue) —
that lowering is the proven template; we port its control-flow skeleton and
replace name-level `ci_*` emission with SSA value construction (§2.7, §3).

### 2.4 Types

A small type-id table interned from the parser's type nodes: `i1, i8, i16, i32,
i64` (Adder's `int8..int64`/`uint*`/`bool`/`char`), `f32, f64`, and `ptr`
(opaque; pointee width carried on the LOAD/STORE `sv_aux` size, LLVM-opaque-ptr
style). Signedness is a per-value attribute bit in `sv_type` (Adder tracks it via
`expr_signedness` in codegen) because it selects signed vs unsigned x86
instructions for compares/div/shr — the exact reason `ir.ad` keeps those
"emit-only" (`ir.ad:248`). Aggregates (structs/arrays) are NOT SSA values; they
live in memory and are accessed via `SVO_GEP`+`SVO_LOAD`/`SVO_STORE`.

### 2.5 Memory model & mem2reg

Two-tier, exactly LLVM's:
1. **Promotable scalars** (not address-taken, not stored-through) become pure SSA
   values with no memory op — this is `mem2reg`. The promotability test is the
   one `cfg.ad` already computes: reuse the `cl_build` escape scan
   (`cfg.ad:1790`) logic — a local is promotable iff its address is never taken
   and it is never the base of a store through a non-ident lvalue. Port that scan
   to mark `SVO_ALLOCA`s as promotable.
2. **Address-taken / aggregate locals** stay in memory as `SVO_ALLOCA` +
   explicit `SVO_LOAD`/`SVO_STORE`. No memory-SSA / no store-to-load forwarding
   across them in the first cut (conservative, matches today's refusal at
   `ir.ad:342`). A later pass may add a light memory-SSA, but it is out of scope
   for the cutover.

This split is the single biggest correctness upgrade: the allocator never again
has to reason about "does a name's slot alias a store". Promoted values have no
memory; memory values are never in registers (except transiently around a
load/store, handled by the machine-IR pass).

### 2.6 Escape hatch (coexistence with the old backend)

If a function contains any construct outside the SSA subset (match/try/with/
defer/yield, address-of-label, an aggregate-by-value shape the lowering doesn't
model, or an arena overflow), SSA construction for THAT FUNCTION **bails and
returns 0**, and codegen falls back to the exact current path for that function —
identical to how `ra_build_cfg` returns 0 on overflow/validation failure
(`regalloc.ad:836-841`) and codegen drops to all-memory. This makes the rewrite
incrementally shippable: a function is either fully on the new pipeline or fully
on the old one, chosen per function, never a mix.

### 2.7 Coexistence with `ir.ad`'s `nd_*` during the gated phase

- `nd_*` (AST) is READ-ONLY to `ssa.ad`. The old `opt.ad` in-place rewrites are
  **not run** in the OPT2 configuration (they are an alternative front-end). The
  new pipeline lowers the *raw parsed AST* → SSA and does all its transforms on
  SSA.
- `ir.ad`'s expression IR and `gen_expr_ir` remain the emit path for the *old*
  `--opt`. OPT2 does not use them; it has its own machine-IR (§4). During the
  alongside phase both compile paths exist in the same binary, selected by the
  gate. Once cutover completes, `ir.ad`/`cfg.ad`/the name-based half of
  `regalloc.ad` and the opt.ad in-place passes are retired.

---

## 3. SSA construction

### 3.1 Algorithm: **Braun et al.** ("Simple and Efficient Construction of SSA
Form", CC 2013), NOT Cytron dominance-frontier.

**Chosen: Braun.** It constructs pruned SSA *directly during AST→IR lowering*,
on the fly, without first computing the dominator tree or dominance frontiers.
Per (block, variable) it records the "current definition"; a read with no local
definition recurses into predecessors, inserting an operandless φ to break cycles
and filling it once predecessors are sealed. For a first, correctness-critical,
self-hosted implementation this is the right pick:
- **No separate DF machinery.** Cytron needs dominator tree + dominance frontiers
  + a worklist φ-placement pass before any renaming — three more algorithms to
  get right in Adder. Braun folds construction into the single lowering walk we
  are already writing to build the CFG.
- **Produces minimal + pruned SSA** for reducible CFGs (everything Adder's
  structured control flow produces) with the trivial-φ-removal rule built in —
  fewer φ to coalesce out later.
- **It's the algorithm modern self-hosting/JIT compilers reach for** for exactly
  this reason.

**Rejected: Cytron et al.** Better asymptotics on pathological CFGs and the
"textbook" choice, but it requires the dominator tree (Lengauer–Tarjan or
iterative) and dominance frontiers as prerequisites — more code, more surface
area, and Adder's structured, reducible CFGs never hit the cases where Cytron
wins. We DO still compute a dominator tree (`sb_idom`, simple iterative
Cooper–Harvey–Kennedy) — LICM and GVN need it — but AFTER construction, as an
analysis, not as a construction prerequisite. This keeps construction and
dominance decoupled and independently testable.

### 3.2 mem2reg during construction

Braun's per-variable "current definition" *is* mem2reg for promotable scalars: a
promotable local never gets an `SVO_ALLOCA`; its reads/writes are pure
value threading. Address-taken locals are materialized as `SVO_ALLOCA` and
their reads/writes stay `SVO_LOAD`/`SVO_STORE` (Braun simply never tracks a
current-definition for them). The promotable set is computed up front by the
ported `cl_build` escape scan (§2.5).

### 3.3 Adder specifics

- **`Ptr` / address-taken.** A local whose address escapes is non-promotable
  (memory alloca). `&x`, `x[i]=e`, `x.f=e`, `*p=e` all mark the base — reuse
  `cl_base_ident` (`cfg.ad:1665`) and `cl_scan_stmts` (`cfg.ad:1723`).
- **Aggregates** (struct/array locals, `Array[N,T]`) are memory, accessed by
  `SVO_GEP`+load/store. Never SSA values.
- **Sub-8-byte scalars.** Width tracked in `sv_type`; loads are `SVO_LOAD` with
  size in `sv_aux`; the allocator promotes them (today they are vetoed —
  `cg_veto_nonlocal_names`, `codegen.ad:3279` — precisely because name-based
  liveness couldn't model the partial-width read; SSA models it exactly).
- **Signedness** rides on the value (§2.4) — a `uint32` and `int32` add are the
  same op, but a compare/div/shr picks the instruction from the operand's
  signedness attribute, matching `expr_signedness` in codegen.
- **percpu / `%gs`** reads become `SVO_PERCPU` values (first-class, §2.2) so the
  machine pass knows they are `%gs`-relative and must not be treated as ordinary
  memory or hoisted across a context switch (§4.5).

### 3.4 The verifier (`ssa_verify`, ships in Phase 1)

Runs after construction (and after every pass in debug/fuzzer builds). Asserts
the SSA invariants — this is the analogue of `cfg_validate` (`cfg.ad:1189`) and
joins the fuzzer's non-codegen lane:
- Every value is defined exactly once; every block has exactly one terminator,
  last in its list.
- **Dominance:** every use is dominated by its def; every φ operand's incoming
  value dominates the corresponding predecessor's terminator.
- Every φ has exactly one operand per predecessor; φ only at block heads.
- Every edge endpoint exists; RPO/domtree consistent; no use of `SVO_UNDEF`
  reaching a return (soft-warn).
- Type check: operand types match the opcode's signature.

A "deliberate-break" switch mirrors the existing pattern (e.g.
`ir_castcall_break_flag`, `ir.ad:559`; `lr_holes_break`, `cfg.ad:1385`): arm a
flag that corrupts one invariant and assert the verifier catches it — proving the
verifier actually guards soundness.

---

## 4. Passes on SSA

Pass order (each is a module `ssa_<pass>.ad`; the pass manager `ssa_opt.ad`
mirrors `opt_run`, `opt.ad:1385`, and honors `ADDER_OPT_DISABLE` names so
bisection keeps working):

```
build SSA ─ verify ─ SCCP ─ InstCombine ─ GVN/CSE ─ LICM ─ DCE ─ verify ─> machine lowering
```

Rationale for order (LLVM canon): SCCP first folds constants and prunes
unreachable edges (feeding everything downstream simpler IR); InstCombine
canonicalizes so GVN sees more congruences; GVN removes redundancy; LICM hoists
what's now provably invariant; DCE sweeps the corpses. Run the middle three to a
small fixpoint (2–3 iterations) like LLVM's function pass loop.

### 4.1 SCCP — Sparse Conditional Constant Propagation
Wegman–Zadeck lattice (undef → const → overdefined) over SSA values *and* CFG
edge reachability, jointly. Folds `SVO_BINOP`/`SVO_ICMP` with constant operands
(reuse `ir_eval_binop`, `ir.ad:396`, and the signed/float eval in
`opt_ffold_eval`, `opt.ad:882`), and marks branch edges dead when the condition
is a known constant — subsuming today's **constfold** (`opt.ad:975`),
**constbranch** (`opt.ad:1275`), and much of **copyprop** (`opt.ad:4736`) in one
pass, done *right* (SCCP is strictly stronger than the separate AST passes: it
propagates through φ and around loops). Dead edges/blocks are removed; φ operands
from dead preds are dropped.

### 4.2 GVN / CSE
Dominator-based value numbering (LLVM `NewGVN`-lite / `EarlyCSE`): hash each
instruction by (op, aux, operand vids); a later instruction with the same number
whose def dominates the use is replaced by the earlier value. This is the
**structural value numbering `ir_value_eq` already does** (`ir.ad:608`) but
(a) global across the whole function via dominance instead of one straight-line
expression, and (b) safe by construction — no name-clobber scan needed, because
SSA values are immutable. Replaces **cse** (`opt.ad:2238`) and **xcse**
(`opt.ad:3927`). Loads through promotable allocas are already gone (mem2reg);
loads from memory allocas are NOT numbered in the first cut (conservative).

### 4.3 LICM — the loop-condition CSE bug, killed structurally
For each loop (from the dominator tree + back-edge detection), an instruction is
loop-invariant iff **all its operands are defined outside the loop or are
themselves invariant**, it has no side effects, and it cannot trap (or is
guaranteed to execute — dominates all loop exits). Hoist invariants to the
pre-header.

The OLD bug (`ir.ad`/`opt.ad` LICM hoisting a loop-condition subexpression that
the body mutates) **cannot recur**: in SSA a value mutated in the body is a
*different value* (or a φ whose def is inside the loop), so it fails the
"operands defined outside the loop" test trivially. The whole hand-built clobber
model (`licm_collect_clobbers`, `opt.ad:2420`; `ir_tree_has_leaf`, `ir.ad:342`)
disappears — invariance is a one-line predicate over operand def-blocks vs the
loop. Trap safety (div/mod) uses the dominates-all-exits test instead of the ad
hoc `ir_tree_has_div` guard (`ir.ad:321`). Replaces **licm** (`opt.ad:2744`).
IVSR (`opt.ad`, induction-variable strength reduction, the matmul index-multiply
win) is retained as a dedicated SSA loop pass in a later increment — it is a real
speed lever (`docs/regalloc_plan.md`) and is cleaner on SSA (φ = the induction
variable), but is NOT required for cutover.

### 4.4 DCE
Mark-sweep over SSA: an instruction is live iff it has a side effect (store,
call, terminator, volatile/percpu access) or feeds a live instruction; sweep the
rest. Trivial and *sound by construction* on SSA — no def/use recount, no
`dce_name_addr_taken` name scan (`opt.ad:4156`). This structurally fixes the
**dead-store-elimination global-cap bug**: a store to a global is a side effect
and is never marked dead; the "global cap" heuristic (`opt_gname_build`,
`opt.ad:458`) that the old bug lived in is deleted. Replaces **dce**
(`opt.ad:4381`).

### 4.5 InstCombine / peephole (light)
Algebraic identities and canonicalization that widen GVN and feed the machine
pass: `x+0`, `x*1`, `x*2^k → shl`, `x/2^k`/`x%2^k → shift/and` for unsigned
(subsumes **paritymod**, `opt.ad:5091`), `(a+C1)+C2 → a+(C1+C2)` reassociation
(the win `ir_add_const_sum`, `ir.ad:961`, was hand-coding), compare-canonicalize
for cmp/jcc fusion. The heavier **strengthreduce** (div-by-constant → multiply-
high, the collatz/`idiv`-elimination win that `docs/regalloc_plan.md` flags as
co-dominant with regalloc) is a dedicated InstCombine sub-pass — it MUST land
before cutover or the perf criterion (§6) fails, since it and the allocator
together, not the allocator alone, reach 1.41× gcc-O2.

### 4.6 Pass → current-pass mapping (summary)

| new SSA pass | replaces (opt.ad / ir.ad) |
|---|---|
| SCCP | constfold `:975`, constbranch `:1275`, copyprop `:4736` |
| GVN/CSE | cse `:2238`, xcse `:3927`, `ir_value_eq` `ir.ad:608` |
| LICM | licm `:2744`, `licm_collect_clobbers` `:2420` |
| DCE | dce `:4381`, dead-store global-cap logic |
| InstCombine | paritymod `:5091`, reassoc `ir.ad:961`; hosts strengthreduce |
| (later) IVSR pass | ivsr `:3483` |
| (unchanged, AST/codegen) | rec2iter, vec, isel LEA-selection, cmpjcc |

---

## 5. Machine-IR lowering + register allocation (the critical part)

### 5.1 Machine IR (MIR)
A thin lowering of SSA to a **machine-IR** in the same arena style: one MIR
instruction per emitted x86 instruction (or small fixed group), operands are
*virtual registers* (= SSA vids, since SSA is already 3-address) plus fixed
physical constraints where the ABI/ISA demands them:
- Two-address fixup: x86 `op src,dst` writes dst, so a `SVO_BINOP a,b` lowers to
  `mov a→vN; op b→vN` (the allocator coalesces the mov when it can, §5.5).
- Fixed-register constraints: `idiv`/`mul` tie to `%rax:%rdx`, shift-count to
  `%cl`, call args to `%rdi,%rsi,%rdx,%rcx,%r8,%r9`, return to `%rax`. Modeled as
  pre-colored virtual registers / clobber sets on the MIR op.
- `SVO_GEP` → `emit_lea_base_index_reg` (`codegen.ad:5198`); `SVO_PERCPU` →
  `%gs`-relative load (`emit_load_gs_rax_sized`, `codegen.ad:3364`) with the base
  **never** allocated to a GPR value (structural, §5.6).

### 5.2 Liveness on MIR
Precise SSA-based live intervals with **lifetime holes** — not the single
`[start,end)` per name of today. Because SSA values are single-def, an interval
is exactly [def-point, last-use-point] with holes where the value is live-through
but unused. This is precisely the model `cfg.ad`'s `lr_build_holes`
(`cfg.ad:1432`) already prototypes (per-name); the SSA version is *sound* because
values don't get redefined. Compute over MIR in RPO with backward use scanning
(standard).

### 5.3 Algorithm: **SSA-based / Extended Linear Scan with lifetime holes**
(Wimmer–Franz / Traub–Holloway–Smith), NOT Chaitin–Briggs graph coloring.

**Chosen: linear scan with holes + interval splitting.** Sort intervals by start;
walk; expire; assign from the free pool; on pressure, split-and-spill the interval
whose next use is furthest (or lowest spill-weight, reusing `nm_usecost`'s
loop-depth weighting, `cfg.ad:244`). Justification for the kernel target:
- **Correctness surface is smaller.** Chaitin–Briggs needs interference-graph
  construction, iterated coalescing, optimistic spilling, and a rebuild loop —
  each a place for a miscompile in a compiler that must BOOT A KERNEL. Linear
  scan is a single ordered walk; the current allocator is already this shape
  (`ra_linear_scan`, `regalloc.ad:709`), so the team knows it and the existing
  spill-cost/pool/ABI logic ports directly.
- **The infrastructure already exists.** Intervals, holes, spill weights,
  per-value call-span classification (`lr_spans_call`, `cfg.ad:1578`), and the
  callee/caller-saved pool split (`regalloc.ad:456-477`) are built and tested.
  The rewrite makes them *value-based instead of name-based*; the allocation
  policy is reused.
- **Compile speed.** Self-hosting on-device wants near-linear allocation, not
  the super-linear graph build. This is why JVM/V8-class JITs use linear scan.
- **Holes recover most of coloring's quality.** The idle-gap machinery
  (`cfg.ad:1330-1553`) already lets a hot loop-invariant reuse a register that a
  long-lived value leaves idle — the main quality gap plain linear scan has vs
  coloring.

**Rejected: Chaitin–Briggs.** Slightly better allocation on high-pressure
functions, but the kernel is overwhelmingly low/medium pressure (the bench
functions fit in 5–10 registers today), and the extra correctness risk is
unacceptable for the thing that blanks the desktop when wrong. Flagged as a
possible *future* upgrade for hot leaf functions only, behind its own gate.

### 5.4 Spilling
An interval that finds no free register is **split** at the optimal point (before
the next use-gap) and the tail spilled to a stack slot (`SVO_ALLOCA`-style frame
slot allocated on demand); a reload interval is inserted before the next use.
Spill victim = lowest loop-depth-weighted next-use (port `ra_cheapest_active`,
`regalloc.ad:665`, and the "keep the hot accumulator" rule that the comment at
`regalloc.ad:744` fought for). Because this is value-based, a spill is a genuine
new short interval, not the write-through-to-a-name's-slot crutch — the
**write-through model (`lr_is_store_elim`, `cfg.ad:1843`) is deleted**; a value
is in exactly one place at each point, and spill/reload are explicit MIR ops.

### 5.5 Coalescing & out-of-SSA (φ elimination)
φ-nodes are removed by inserting parallel copies on predecessor edges
(Sreedhar/Boissinot conventional-SSA method; the parallel-copy sequentialization
handles swap cycles). Then **move coalescing**: if a copy's src and dst intervals
don't interfere, give them the same register and delete the move. This is the
only coalescing we do (aggressive Briggs coalescing is out — keep it simple);
it removes the two-address `mov`s from §5.1 and the φ copies. Coalescing is an
interval-merge check, cheap on the linear-scan side.

### 5.6 The four things the OLD allocator gets wrong — explicit handling

1. **Callee-saved save/restore on EVERY return path.** The set of callee-saved
   registers the allocator used is derived from the *authoritative assignment*
   (as today: `cg_pool_saved` → `ra_pool_used`, `codegen.ad:3104`/`regalloc.ad:1103`
   — the one-source-of-truth rule that prevents save-set desync, and the memory
   note "method-prologue corruption" it fixed). The prologue pushes them
   (`emit_push_callee`, `codegen.ad:2979`); the epilogue pops them at **every**
   `SVO_RET` lowering via the unified `emit_function_epilogue`
   (`codegen.ad:3334`) — SSA guarantees every path ends in exactly one terminator,
   so there is no "path that forgot to restore". The verifier asserts every block
   ends in a terminator, closing the class structurally.
2. **`%gs`/percpu addressing surviving allocation.** `SVO_PERCPU` is a distinct
   opcode; its `%gs`-relative base is never a virtual register the allocator can
   place in a GPR, and the value it loads is an ordinary GPR value like any load.
   No pass may hoist an `SVO_PERCPU` across a call/context-switch boundary (LICM
   treats it as a possibly-changing memory read unless the function is
   demonstrably non-preemptible — conservative default: not hoistable).
3. **Cross-call ABI (caller- vs callee-saved).** A call site clobbers the
   caller-saved set; any value live across a call must be in a callee-saved
   register or spilled. This is the per-value `lr_spans_call` gate
   (`cfg.ad:1578` / `ra_pool_cap_for`, `regalloc.ad:637`), now exact because SSA
   liveness is exact: a value's live interval either contains a call point or it
   doesn't, and the caller-saved extension pool is offered only to call-free-
   lifetime intervals — same policy, sound inputs.
4. **Interrupt-safety at the kernel target.** The kernel is compiled -O0 today and
   stays -O0 until cutover. When the allocator does target kernel code, the
   invariant is: the register file the allocator uses is exactly the SysV
   callee/caller split, interrupts save/restore the full GPR file (kernel entry
   already does), and no value is assumed live across an instruction boundary in a
   register the interrupt path could clobber — which SysV already guarantees for
   callee-saved. `%gs` base is never reallocated (point 2). No red-zone use
   under -mno-red-zone semantics: the frame is explicit, spills go to reserved
   slots below `%rsp`-adjust, never to the red zone.

### 5.7 MIR → encoder interface
The MIR emitter is a straight walk producing `emit_*` calls with concrete
encodings from the allocation:
- `mov vsrc→vdst` (post-coalesce residual) → `emit_mov_reg_reg(enc(vsrc), enc(vdst))`
  (`codegen.ad:4244`).
- `binop` → `emit_alu_reg_reg(op, enc(b), enc(dst))` (`codegen.ad:4253`) or
  `emit_alu_imm_reg` (`codegen.ad:4327`) / `emit_alu_mem_reg` for a spilled
  operand (`codegen.ad:4369`).
- compare → `emit_cmp_reg_reg` (`codegen.ad:4412`); GEP → `emit_lea_base_index_reg`
  (`codegen.ad:5198`); spill/reload → `emit_store_local_callee`/
  `emit_load_local_callee(enc,off)` (`codegen.ad:3049`/`3033`); percpu →
  `emit_load_gs_rax_sized` (`codegen.ad:3364`).
The encoder is **unchanged** — it already accepts arbitrary encodings 0..15 via
`ir_rex_src_dst`/`ir_modrm_src_dst` (`codegen.ad:4229`/`4239`). The MIR layer is
the new code; the byte layer is reused.

---

## 6. Integration, gating, cutover

### 6.1 Alongside, gated
- New gate `ADDER_OPT2` (env / `--opt2` flag), parsed next to `--opt` in
  `fused_driver_host_main.ad:1285` and the dump driver. `ssa_enabled` defaults 0.
- Per function, in `gen_function` (`codegen.ad:17686`), *before* the current
  regalloc block (`codegen.ad:17812`): if `ssa_enabled` and the function is in the
  SSA subset, run build→verify→passes→MIR→allocate→emit through a new
  `gen_function_ssa(fn)` and return; else fall through to the exact current path.
  This is the per-function escape hatch (§2.6) — a function is wholly OPT2 or
  wholly legacy.
- `ADDER_OPT_DISABLE` names extend to the SSA passes (`sccp, gvn, licm2, dce2,
  instcombine`) so host bisection of an OPT2 miscompile works the same way the
  current per-pass mask does (`opt.ad:247`).
- The OS/kernel build passes neither `--opt` nor `--opt2` → pure -O0 → byte-
  identical ship path, unchanged, for the entire alongside period.

### 6.2 Cutover criteria (ALL must hold, in order)
1. **Differential fuzzer 500/500.** `FUZZ_COUNT=500 ADDER_OPT2=1
   scripts/fuzz_adder_diff.sh` green; then a soak `FUZZ_COUNT=5000`. Zero
   miscompiles (accepted-but-wrong). The SSA verifier lane green over the corpus.
2. **Perf ≥ 1.41× gcc-O2** on `scripts/bench_opt.sh` (`docs/bench_opt_results.md`
   geomean) with OPT2 — i.e. at least matching today's full `--opt`. This REQUIRES
   strength-reduction + basic instruction selection in the OPT2 path (§4.5, §5),
   not the allocator alone.
3. **Kernel boots + desktop renders** under the shipped OVMF image with the
   kernel compiled `--opt2` — the real acceptance (memory: host-gate-green ≠
   device-working; acceptance = drive the image). Verify by VIEWING the rendered
   desktop PNG, not a green gate.
4. Only then flip the OS build to `--opt2` and begin retiring `ir.ad` /
   `cfg.ad` name-based liveness / the write-through half of `regalloc.ad` / the
   `opt.ad` in-place passes.

### 6.3 A/B safety net
Keep `ADDER_RA_ONLY_FILE`/`ADDER_RA_SKIP_FILE`-style per-function selection
(`regalloc.ad:178`) for OPT2: a per-function allow/deny list lets the orchestrator
bisect a single miscompiling function on-device without rebuilding, exactly as the
current allocator supports.

---

## 7. Phased implementation plan

Each phase is independently testable and dispatchable. Effort is relative
(1 = a focused agent-week-equivalent unit).

### Phase 1 — SSA IR + construction + verifier + round-trip  (effort 3, risk: MED)
Deliverables: `ssa.ad` (arenas, opcodes, blocks, types), AST→SSA lowering
(Braun, §3), dominator tree (`sb_idom`), `ssa_verify` (§3.4) with a deliberate-
break switch, and a **round-trip emitter**: lower SSA straight back to machine
code via the existing `emit_*` primitives with a TRIVIAL allocator (every value
→ its own stack slot, all-memory, like -O0) — no optimization yet.
Acceptance: `ADDER_OPT2=1` differential fuzzer 500/500 with the trivial-alloc
round-trip (proves construction + emission are value-preserving), verifier green
over the corpus, per-function escape hatch falls back cleanly on non-subset
functions. **Riskiest bit:** Braun φ construction + sealing for loops (back-edges)
— the sealing order must be right or reads pick up stale defs. Mitigate with a
dedicated unit corpus of loop/if/nested-loop shapes and the verifier's dominance
check.

### Phase 2 — SSA passes  (effort 2, risk: LOW-MED)
Deliverables: SCCP, InstCombine (incl. pow2/reassoc; strength-reduce sub-pass),
GVN/CSE, LICM, DCE, pass manager with `ADDER_OPT_DISABLE` names, fixpoint loop.
Each pass runs verify after it in fuzzer builds.
Acceptance: fuzzer 500/500 with passes ON (still trivial allocator, so this
isolates the transforms from the allocator); each pass demonstrably fires on a
targeted corpus (counters like `opt_*_count`); the loop-condition-CSE and
dead-store-global fuzzer regressions that broke the old passes now pass.
**Riskiest bit:** LICM trap/exit-dominance safety and SCCP's φ/edge lattice
interaction — but both are well-specified and the verifier + differential fuzzer
catch mistakes immediately.

### Phase 3 — the register allocator  (effort 4, risk: HIGH — the payload)
Deliverables: MIR lowering (§5.1), SSA liveness with holes (§5.2), linear-scan
with splitting/spilling (§5.3–5.4), φ-elimination + coalescing (§5.5), the four
correctness handlers (§5.6), MIR→encoder emission (§5.7). Reuse the pool/spill-
cost/call-span policy from `regalloc.ad`.
Acceptance: fuzzer 500/500 AND 5000 soak with the allocator ON; `bench_opt.sh`
≥ the current full-`--opt` numbers; the `ra_diff_onoff.py`-style on/off
differential green. **Riskiest bits:** (a) φ-elimination parallel-copy
sequencing (swap cycles) — use the proven Boissinot algorithm and a swap-heavy
unit test; (b) two-address/fixed-register constraints for `idiv`/shift/call args;
(c) callee-saved save-set correctness on every return path (mitigated by the
one-source-of-truth rule, §5.6.1). This phase is where the systemic miscompile
lived; budget the most verification here.

### Phase 4 — cutover  (effort 2, risk: HIGH — real-HW acceptance)
Deliverables: extend `ADDER_OPT_DISABLE` fully; wire the OS/kernel build to
`--opt2`; meet §6.2 criteria 1–3; flip the ship build; begin retiring the old
IR/opt/name-based-regalloc modules (as a follow-up, not gating cutover).
Acceptance: the four §6.2 criteria — culminating in **kernel boots + desktop
renders on the OVMF image**, verified by viewing the PNG. **Riskiest bit:** a
bug that only manifests on the kernel target (percpu/interrupt/SMAP interactions
TCG masks) — use the KVM-fidelity probe and per-function on-device bisection
(§6.3) rather than trusting host gates.

**Total relative effort ≈ 11.** Critical path and risk are concentrated in
Phase 3 (allocator) and Phase 4 (real-HW acceptance); Phases 1–2 are lower risk
because the differential fuzzer validates them fully on the host.

---

## 8. Risks & mitigations (top of list)

1. **Phase 3 allocator miscompiles the kernel (the exact class we're fixing).**
   Mitigation: value-based (not name-based) liveness makes the whole class
   structurally harder; the verifier + 5000-program soak + on-device per-function
   bisection (§6.3) + the one-source-of-truth save-set rule. Do NOT trust host
   green — acceptance is the rendered desktop.
2. **Perf regresses vs today's full `--opt` because strength-reduce/isel weren't
   ported.** `docs/regalloc_plan.md` shows the allocator alone doesn't reach
   ≤2× gcc-O2. Mitigation: §4.5 makes strength-reduction a gating part of Phase 2;
   keep the AST-level `isel` LEA-selection / `cmpjcc` / `vec` levers as-is
   (they compose with OPT2 codegen).
3. **Braun loop-sealing / φ bugs (Phase 1).** Mitigation: verifier dominance
   check + targeted loop corpus before moving to Phase 2.
4. **Arena sizing** (SSA values per function). Mitigation: escape-hatch bail on
   overflow → legacy path (§2.6), exactly like `cfg_overflow` today; size arenas
   from the largest kernel function measured on the host.
5. **Scope creep into memory-SSA / graph-coloring.** Mitigation: both are
   explicitly deferred; the cutover subset is fixed (§2.2, §5.3).

---

## 9. What is retired after cutover (not before)
`ir.ad` (expression IR + `gen_expr_ir` consumer), `cfg.ad` name-level liveness /
intervals, the write-through half of `regalloc.ad` (`ra_reg_for_name` and the
slot-authoritative model), and the `opt.ad` in-place AST passes. The hand-written
`emit_*` encoder, `elf_emit.ad`, the AST/parser, and the `isel/cmpjcc/vec/rec2iter`
levers **stay**. Retirement is a follow-up cleanup gated on OPT2 being the ship
default — never a prerequisite for it.
