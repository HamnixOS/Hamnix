# Adder language roadmap — safe, Python-shaped, kernel-capable

**North star (USER, 2026-07-14):** make Adder the best **systems *and* app** language we
can — for **AI agents and humans**. That means: safe by default so mistakes fault
cleanly instead of corrupting memory; Python-shaped so it's pleasant and predictable
to write (and easy for an LLM to emit correctly); expressive enough for real apps; and
still first-class for kernel work, where raw pointers/MMIO and zero overhead are the
whole point.

Companion doc: `docs/adder_memory_safety.md` (the bounds-check increments 1/1b/2, shipped).

## Design invariants (every increment obeys these)

1. **Kernel opt-out is sacred.** No safety feature is ever forced on `x86_64-bare-metal`.
   Runtime checks are never emitted for the kernel; compile-time checks are zero-cost.
2. **Byte-inert when unused.** New features must not perturb the emitted bytes of code
   that doesn't use them — the frozen Python seed (`codegen_x86.py`) is the objdiff
   oracle for the native `.ad` backend (`codegen.ad`); the differential fuzzer +
   `test_native_kernel_links` guard the lockstep. New syntax is opt-in *by use*.
3. **Seed + native in lockstep.** Anything the native backend emits, the seed must emit
   identically (objdiff on `x86_64-adder-user`), or it's rejected.
4. **Incremental, not big-bang.** Land the cheap high-value wins first; the heavy
   compile-time analyses (ownership/regions) come last, and stay opt-in.
5. **No codegen-perf regression (USER, 2026-07-14).** Adder-compiled code is at
   **geomean 1.83× of `gcc -O2`** (the `-O2` register-promotion pipeline, `BENCH_OPT=2
   bash scripts/bench_adder_host.sh`) — inside the ≤2× target. Every increment must keep
   that number **flat or better, never slower**. Invariant #2 (byte-inert-off) protects
   it structurally — code that doesn't use a new feature objdiffs identical, so it runs
   identically — but any increment that touches the emitted-instruction path (not just
   opt-in-by-use syntax) must run the bench and show no regression. Making the generated
   code *faster* is squarely in scope of "best systems language" — optimizer wins count
   as roadmap progress, not a distraction.

## Where Adder already is (strong base)

Python-shaped: indentation blocks, `def`, `for`/for-unpack, `while`, `with`,
`try/except/finally`, `raise`, `assert`, **`match`**, **`lambda`**, list/dict/tuple
literals + **comprehensions**, **f-strings**, slicing, ternary, `import/from`, `defer`.
Types: `int*/uint*/float*/bool`, `Ptr[T]`, `Array[N,T]`, `List[T]`, `Dict[K,V]`,
`Tuple[…]`, `Fn[…]`, `Optional[T]`, struct/`union`, `Volatile[T]`.
Systems: `cast`, `sizeof`, inline `asm`, `volatile`, `container_of`, `extern`, `unsafe:`.
Safety: opt-in runtime **array-bounds checks** (`--check-bounds`), `unsafe:` opt-out,
kernel-exempt, byte-inert-off (increments 1/1b/2).

## The Rust-safety question — what we take, what we skip

Rust's guarantees are **compile-time** (ownership/borrow/lifetimes). Porting that
wholesale is wrong here: it's a huge investment in a self-hosted compiler, and it
actively fights kernel code (real Rust kernels are `unsafe {}` soup). Adder's sweet
spot is a **hybrid**:

- **Tier A — runtime, opt-in, kernel-bypassable** (cheap, incremental): bounds (done),
  null-deref checks, `Slice[T]` fat-pointer bounds, integer-overflow + uninit-read
  checks, descriptive traps.
- **Tier B — lightweight compile-time, zero runtime cost** (kernel pays nothing):
  move-only `own T` handles with auto-`drop` (affine types → no use-after-free /
  double-free without a full borrow checker); region/arena lifetimes (fits the slab
  model) as a scoped, function-local check.
- **Tier C — deliberately skip**: full borrow checker with lifetime generics,
  `Send`/`Sync` data-race typing, trait-bound generics. Too heavy; hurt "simple
  self-hosted + good at kernel work."

## Roadmap (ordered; "do it all" — run autonomously)

1. **★ Tagged sum types + `Result`/`Option` + `?`** — the keystone. Adder has C-style
   untagged `union` + `match` but no tagged enums, so no safe Option/Result. Add
   `enum` with payload variants, exhaustive `match`, a prelude `Result[T,E]`/`Option[T]`,
   and `?` propagation (desugars to a branch — zero runtime, kernel-friendly). One
   stroke gives safe error handling **without exceptions**, safe nullability, and the
   most Rust+Python thing there is.
2. **Non-null-by-default** pointers/refs + opt-in `Optional` deref checks (leans on #1).
3. **Descriptive bounds/null trap** (`bounds: idx N of len M at file:line`) + **`@unsafe`
   / `unsafe def`** attribute + `# adder: unsafe` file pragma (small, already designed).
4. **`Slice[T]` fat pointers** — dynamic-buffer bounds checks; `Ptr[T]` stays the raw
   escape hatch.
5. **`own T` move-only handles + `drop`** (Tier B) — the biggest Rust-like leap, as a
   compile-time affine check; catches UAF/double-free. Uses the existing `defer`.
6. **Region/arena lifetimes** (long-horizon) — scoped "ref can't outlive region."
7. **App-ergonomics sugar** (interleaved): default/keyword args, string methods, richer
   `match` (exhaustiveness warnings), closures that capture env, a small app std-lib
   (collections/strings/io), integer-overflow-checked arithmetic opt-in.

Each increment: opt-in or byte-inert-off, kernel-bypassable, seed+native lockstep,
verified by objdiff + differential fuzzer + `test_native_kernel_links` +
`run_compiler_tests` + a new feature gate.
