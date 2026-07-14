# Memory safety in Adder

Status: **increment 1 + 1b + 2 landed** (opt-in runtime array-bounds checking for
userspace, with an `unsafe:` opt-out). Increment 1 landed the checks in the
frozen Python seed (the oracle); **increment 1b mirrors them into the native
`.ad` backend** (`adder/compiler/codegen.ad` + `parser.ad` + the host driver),
so the DEFAULT shipping compiler emits the identical bytes; **increment 2 extends
the native check to the `--opt` isel index paths** (direct-SIB register +
index-into-`%rcx`), which previously routed the index out of `%rax` and silently
dropped the check (see roadmap item 2b). This document is both the design and the
roadmap.

## Motivation & constraints

Adder is Hamnix's self-hosted systems language. It compiles **both** the
kernel (`--target=x86_64-bare-metal`) and userland (`--target=x86_64-linux`,
`--target=x86_64-adder-user`). Today the language is C-like/unsafe: raw
`Ptr[T]`, unchecked `arr[i]`, unchecked casts.

We want the *usability* win of memory safety — an out-of-bounds index in an
app faults cleanly instead of silently corrupting memory — **without** taxing
the kernel, where raw pointer and MMIO work is the whole point and every cycle
counts. So memory safety in Adder is built around a **clean, explicit
opt-out**, and it is layered in incrementally rather than as a big-bang
Rust-style ownership system.

Two hard invariants shaped the design:

1. **Kernel code must be able to bypass all checks** and stay byte-for-byte as
   fast as today. Checks are *never* emitted for a bare-metal target.
2. **The change must be byte-inert when off.** Adder's native `.ad` backend
   (`adder/compiler/codegen.ad`) is the default compiler; the frozen Python
   seed (`adder/compiler/codegen_x86.py`) is its oracle, kept in lockstep and
   guarded by objdiff + the differential fuzzer. Anything that perturbed the
   emitted bytes of existing kernel/userland code would break that lockstep
   and the whole boot. So instrumentation is **opt-in** and every emission
   site is guarded — with the feature off, codegen output is identical to the
   pre-feature compiler.

## What is checked (increment 1)

**Runtime array-bounds checks on `Array[N, T]` indexing**, where `N` is a
compile-time constant. For `a[i]` (load *or* store) the compiler emits, right
after evaluating the index:

```asm
    cmpq $N, %rax        # %rax = index (evaluated once)
    jb   .bcheck_ok_…    # unsigned: 0 <= index < N  -> in range
    ud2                  # out of range -> trap
.bcheck_ok_…:
```

Design points:

* **One unsigned compare covers both ends.** A negative index reinterpreted as
  unsigned is a huge value `>= N`, so `jb` (unsigned "below") rejects both
  `index < 0` and `index >= N` with a single branch — no separate low-bound
  test.
* **The index is evaluated exactly once.** The check reuses the value already
  in `%rax`; it does not re-evaluate the index expression, so a side-effecting
  index (e.g. `a[i := i + 1]`) stays correct.
* **In-range path adds one `cmp` + one not-taken `jb`.** No register is
  clobbered on the fast path, so the surrounding address computation is
  unchanged.
* **Scope: fixed-size arrays only.** `Ptr[T]` carries no length and is left
  unchecked in this increment (see roadmap). Multi-dimensional arrays are
  checked per level: each `[…]` in `grid[r][c]` bounds-checks against that
  level's constant extent, because each level flows through the same
  `gen_index_address` chokepoint.

### Trap behavior

* **Userland:** `ud2` raises `#UD`, delivered as **SIGILL** — a clean,
  deterministic, non-recoverable fault. The process dies (wait-status 132 =
  128 + SIGILL) instead of scribbling on memory. Increment 1 keeps this
  message-free for byte-economy and simplicity; a descriptive
  `__bounds_fail(file, line, idx, len)` panic helper is a small follow-up
  (see roadmap).
* **Kernel:** checks are **never emitted** — bounds violations behave exactly
  as they do today (undefined; the kernel is trusted). This is enforced at the
  driver, not just by convention (below).

## The opt-out

Two mechanisms; increment 1 ships the first, the design covers both.

### `unsafe:` block (shipped)

```python
unsafe:
    dst[i] = raw_read(mmio_base)   # no bounds check inside this block
```

`unsafe` is a **soft keyword** — recognized only in statement position when
immediately followed by `:` and a newline, so it remains usable as an ordinary
identifier and is unambiguous against a `unsafe: Type = …` variable
declaration. The block is *semantically transparent*: it introduces no scope,
no frame, only a codegen instrumentation toggle (a depth counter, so nesting
composes). Bodies inside an `unsafe:` block emit no bounds checks even when
`--check-bounds` is on.

### `@unsafe` / `unsafe def` (designed, next increment)

A per-function attribute that suppresses checks for a whole function — the
natural annotation for hot paths and driver code. The seed already carries a
decorator channel on `FunctionDef`; wiring `@unsafe` through is a small change
(the current top-level-decorator rejection would need to whitelist it). A
per-file pragma (`# adder: unsafe`) is the coarsest form and is deferred.

### Target-level opt-out (automatic)

Kernel/bare-metal targets are **always** unchecked. The driver only turns
instrumentation on for a *userspace* target:

```python
do_bounds = check_bounds and spec.get("userspace", False)
```

`x86_64-bare-metal` has `userspace = False`, so `--check-bounds` is a no-op
for it and kernel bytes never change.

**`x86_64-adder-user` is now bounds-eligible (increment 1b).** It shares the
bare-metal *codegen* path (`bare_metal = True`, RIP-relative, no `.modinfo`)
but is genuine CPL-3 userspace whose `#UD` faults the Adder kernel delivers as
a clean signal — so the gate treats it as eligible:

```python
userspace_bounds = spec.get("userspace", False) or target == "x86_64-adder-user"
do_bounds = check_bounds and userspace_bounds
```

This matters because the native backend's ONLY userspace target *is*
`x86_64-adder-user` (the on-device user ELF, `ELF_FMT_USER`). Promoting it in
the seed keeps seed and native in **lockstep on the flag** — the differential
objdiff (`scripts/test_native_vs_seed_objdiff.sh`) compares them on this exact
target, so an on-flag divergence (native emits a check, seed does not) would
break the gate. The native driver mirrors the gate: it sets `cg_check_bounds`
only for `ELF_FMT_USER`, never `ELF_FMT_KERNEL`.

## How it is gated (default OFF, opt-in)

Increment 1 is **opt-in via `--check-bounds`, default off.** Justification:

* **Stability / byte-inertness.** Default-off means the entire existing corpus
  (kernel + userland) compiles to identical bytes, so the seed↔native lockstep,
  objdiff, and the differential fuzzer stay green with zero risk. Turning
  checks on by default would be a codegen-wide byte change gated on getting
  every index path perfectly right first — exactly the big-bang we want to
  avoid.
* **Kernel safety is structural, not a flag default.** Even with the flag on,
  the target gate keeps the kernel unchecked.

The flag threads: `adder compile … --check-bounds` → `get_generator(…,
check_bounds)` → `generate(program, bare_metal, check_bounds)` →
`X86CodeGen(check_bounds=…)`. When `check_bounds` is `False`,
`_maybe_emit_bounds_check` returns immediately and emits nothing.

## Implementation map (increment 1)

Native-testable, seed-implemented; native codegen.ad left untouched (and thus
byte-inert + lockstep-safe). All in the seed / driver:

| File | Change |
|------|--------|
| `adder/compiler/ast_nodes.py` | `UnsafeStmt(body)` node; added to `Stmt`. |
| `adder/compiler/parser.py` | parse `unsafe:` soft-keyword block. |
| `adder/compiler/codegen_x86.py` | `check_bounds`/`unsafe_depth` state; `UnsafeStmt` codegen; `_maybe_emit_bounds_check`; call site in `gen_index_address`; `generate(..., check_bounds)`. |
| `adder/compiler/adder.py` | `--check-bounds` flag; userspace-only gating in `get_generator`; thread through `compile_source`/`compile_with_imports`. |
| `tests/membounds/*.ad`, `scripts/test_adder_bounds_check.sh` | regression test. |

Increment 1b (native mirror):

| File | Change |
|------|--------|
| `adder/compiler/codegen.ad` | `cg_check_bounds`/`cg_unsafe_depth` state; `maybe_emit_bounds_check` + call sites in `gen_index_addr`; `ND_UNSAFE` in `gen_stmt` + `prescan_block`. |
| `adder/compiler/parser.ad` | `ND_UNSAFE` node; `unsafe:` soft-keyword parse; `tok_text_is` helper. |
| `adder/compiler/fused_driver_host_main.ad` | `--check-bounds` flag; userspace-only `cg_check_bounds` gate (never kernel). |
| `adder/compiler/adder.py` (seed gate) | `x86_64-adder-user` promoted to bounds-eligible so seed↔native stay in lockstep on the flag. |

### Why seed-first, native next

The bounds check lives in the frozen Python seed (the oracle) because it is
fully host-runnable: the regression test compiles real ELFs to
`--target=x86_64-linux`, runs them, and observes the SIGILL directly — a true
end-to-end proof. Because the feature is default-off, the native `.ad` backend
(`codegen.ad`) is completely untouched, so kernel links, objdiff, and the
fuzzer are unaffected. **Increment 1b** mirrors the same guarded block into
`codegen.ad` (the chokepoint is `gen_index_addr` there, which already mirrors
`codegen_x86.gen_index_address` line-for-line) so the *default shipping*
compiler emits checks too. Until then, `--check-bounds` is honored by the seed
path (host userspace builds, the fuzzer, the compiler test battery).

## Verification (increment 1)

* `scripts/test_adder_bounds_check.sh` — OOB checked index traps (SIGILL /
  status 132); in-range checked index runs (exit 10); `unsafe:` suppresses the
  trap (exit 0); bare-metal + `--check-bounds` emits no `ud2`; userspace
  without the flag emits no `ud2`.
* `scripts/test_native_kernel_links.sh` — **PASS**; the native compiler still
  links the kernel with no seed fallback (kernel unaffected).
* **Byte-inert-off:** the default (no-flag) asm output of dozens of real
  self-contained `.ad` fixtures (incl. array-heavy `sieve`, `mmul`,
  `nested_frame_array`, `cast_arr_u32`, `bigmmap`) is md5-identical between the
  new compiler and committed `HEAD`, on both `x86_64-bare-metal` and
  `x86_64-linux`.
* `scripts/run_compiler_tests.sh` — **ALL PASS** (seed + native codegen.ad
  round-trips), confirming no parse/codegen regression.

## Roadmap beyond increment 1

Ordered by value/effort; each stays opt-in + kernel-bypassable.

1. **Descriptive trap.** Replace bare `ud2` with a `__bounds_fail` userspace
   helper that writes `"bounds: idx N of len M at file:line\n"` to fd 2 and
   `exit_group(134)`. Pass idx/len/site via a tiny out-of-line slow path so the
   fast path stays one `cmp`.
2. **Mirror into `codegen.ad` (increment 1b) — DONE.** The same guarded block
   is emitted by the native backend so the default compiler instruments
   userspace. Chokepoint: `gen_index_addr` calls `maybe_emit_bounds_check` right
   after the index lands in `%rax` in every `Array[N,T]`-base branch (local /
   global / multi-dim / nested / `Array[N,Struct]` global / array member);
   `Ptr[T]`/cast/call/string/scalar bases carry no length and self-gate to a
   no-op via `expr_array_type == 0`. Bytes match GNU `as`
   (`48 83 F8 ib | 48 81 F8 id` / `72 02` / `0F 0B`). `unsafe:` is a native
   soft-keyword (`parser.ad`, `ND_UNSAFE`) and suppresses via `cg_unsafe_depth`.
2b. **`--opt` co-instrumentation (increment 2) — DONE.** Under `--opt` the native
   isel lowers a flat-array index straight into a register (never `%rax`) via one
   of two paths, both of which previously SKIPPED the `%rax`-only check:
   * the **direct-SIB coalesce** — a bare full-width register-promoted index goes
     straight into the SIB index register `idxreg` (`index_reg_direct`), and
   * **`try_sel_index_into_rcx`** — a binary index computed straight into `%rcx`.

   `gen_index_addr` now calls `maybe_emit_bounds_check_reg(node, reg)` (a
   register-parametrized form of `maybe_emit_bounds_check`, `reg` = the encoding
   holding the index: `idxreg`, or `%rcx`=1) right before the address `lea` reads
   that register: `cmp $N,%reg; jb +2; ud2` (`emit_cmp_imm_reg` adds REX.B for
   `reg>=8`). `cmp/jb/ud2` do not clobber the index register, so the SIB address
   is unaffected. Still guarded by `cg_check_bounds`/`cg_unsafe_depth`, so it is
   byte-inert when off and honors `unsafe:`. The SEED needs no change: its `--opt`
   is a text peephole/regalloc post-pass over asm the opt-0 codegen already
   emitted with the check, so the `cmpq $N,%rax; jb; ud2` survives (verified: the
   OOB fixtures trap at `-O0/-O1/-O2`). Lockstep here is BEHAVIORAL — the
   byte-exact objdiff runs at opt-0 (unchanged), and both backends now trap a
   `--opt`-compiled OOB index (wait-status 132) and run in-range code unaffected.
   Verified by `scripts/test_adder_bounds_check_opt.sh` (both isel shapes, both
   backends) + the `ADDER_OPT=1 ADDER_CHECK_BOUNDS=1` differential-fuzzer lane.
3. **`@unsafe` / `unsafe def` + `# adder: unsafe` file pragma.**
4. **Sized slices / length-carrying pointers.** A `Slice[T] = {ptr, len}` fat
   pointer so dynamically-sized buffers get the same check; `Ptr[T]` stays the
   raw escape hatch.
5. **Null-pointer deref checks.** Optional check on `p[0]`/`p.field` for a
   `Ptr[T]` known-nullable, same opt-out story.
6. **Use-after-free / lifetimes.** Region/arena tagging first (cheap, fits the
   kernel's slab model), then opt-in ownership/borrow analysis at the type
   level — the long-horizon goal, deliberately last so the cheap runtime wins
   land first.

Everything above preserves the two invariants: **kernel opt-out** and
**byte-inert when off.**
