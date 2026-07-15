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

   **STATUS (increment 1, SEED backend — landed):** `enum` decls (indented or
   inline `;` form), variant construction (`E.V` / `V` / `E.V(a)` / `V(a)`),
   `match` with payload binding + a non-exhaustiveness *warning*, prelude
   `Option`/`Result`, and postfix `?` propagation all work end to end — compile
   **and run** on `x86_64-linux`, compile for `x86_64-adder-user`, and stay
   **zero-cost** on `x86_64-bare-metal` (no `ud2`/alloc; `?` = a plain tag
   compare + early return). Gate: `scripts/test_adder_enums.sh`.

   *Representation:* an enum value is a single 64-bit **scalar-packed** tagged
   union — an 8-bit tag in the low byte, payload fields packed above it — so it
   flows through the existing scalar codegen (params, **returns**, `?`) with no
   new ABI, no allocation. This is what makes `Result`/`Option` returnable given
   Adder has no by-value aggregate ABI.

   **STATUS (increment 1b, NATIVE backend — landed):** `match`, `enum`, variant
   construction, `?` propagation, the prelude `Option`/`Result`, and the
   `return None` → `Option.None` coercion are now ported to the **native `.ad`
   backend** (`lexer.ad` lexes `enum`/`?`; `parser.ad` parses `enum` decls, the
   postfix `?`, and `case None`; `codegen.ad` registers the scalar-packed enum
   layout and DESUGARS ctor/`?`/`match` to shift/and/or/if/return AST built with
   `node_new` and routed through the byte-tested `gen_expr`/`gen_stmt`). The
   prescan reserves the `match`/`?` temp + payload-binding slots in the seed's
   exact allocation order, so **seed + native emit byte-identical machine code**.
   Verified: `test_adder_enums` PASS (incl. a native objdiff-lockstep step);
   objdiff **254/260 native-accepted, 0 diverged** (was 253 — enum_smoke now
   native-accepted CLEAN, every enum-free unit byte-inert); differential fuzzer
   **500/500, 0 miscompiles**; `test_native_kernel_links` PASS (the native
   compiler still links the kernel with no seed fallback); `run_compiler_tests`
   ALL PASS; the `-O2` bench is byte-identical to HEAD (no `.py`/seed change, so
   no codegen-perf regression). The enum desugar is target-independent, so the
   kernel stays zero-cost on `x86_64-bare-metal` on the native path too.

   *Deferred (disproved for one pass):* (a) **generics** — `Option`/`Result`
   are monomorphized to an `int32` payload; full `[T]`/`[T,E]` generics are a
   follow-up. (b) **multi-word enums** — a variant whose tag+payload exceeds 64
   bits (e.g. a `Ptr` + `int`, or any `int64` payload) is rejected with a clear
   "multi-word enum deferred" error (both backends); supporting them needs an
   sret/`rax:rdx` return ABI. (c) **native non-exhaustiveness** — the native
   backend emits the same stderr "non-exhaustive match" warning; a same-name
   binding reused across two `match` arms still shares one slot on native (the
   pre-existing re-decl divergence), untested by the current fixtures.
2. **Non-null-by-default** pointers/refs + opt-in `Optional` deref checks (leans on #1).

   **STATUS (increment 2, null-safety — landed, opt-in Optional-deref half):**
   A postfix **`!` force-unwrap** operator on `Option[T]`/`Result[T,E]`:
   `opt!` evaluates to the success variant's (Some/Ok) unwrapped payload. Under
   the opt-in **userspace safety flag** (reused `--check-bounds` — the
   established flag + `userspace && flag` gate, so the KERNEL is structurally
   exempt), a non-success value (None/Err) **traps CLEANLY** with `ud2` →
   SIGILL (wait-status 132) — the null-safety mirror of the array-bounds check,
   not a silent garbage-payload read. **Byte-inert when off:** with the flag
   clear (and ALWAYS on `x86_64-bare-metal`, where the driver never sets it) NO
   check is emitted, so `!` is a zero-cost payload extraction that assumes
   success — kernel-friendly and inert for code that uses no `!`. `unsafe:`
   suppresses the trap like it does for bounds (`cg_unsafe_depth`).

   *Both backends, byte-lockstep.* The seed (`lexer.py`/`parser.py`/
   `ast_nodes.py` `UnwrapExpr`/`codegen_x86.py` `_gen_unwrap`) and the native
   `.ad` backend (`lexer.ad` `TOK_BANG`; `parser.ad` `ND_UNWRAP`; `codegen.ad`
   `gen_unwrap` + `prescan_reserve_tries`) emit **byte-identical** machine code
   — the emitted check is `cmpq $0,%rax; je +2; ud2` (`48 83 F8 00 / 74 02 /
   0F 0B`). objdiff CLEAN on both flag states; the lexer's lone-`!` was
   previously a hard error, so no existing corpus byte moves. Lowering desugars
   through the shared enum-extract machinery (materialise-once into a
   prescan-reserved int64 temp, exactly like `?`), so it inherits increment 1's
   scalar-packed representation with no new ABI. Gate:
   `scripts/test_adder_null_safety.sh`.

   *Deferred (disproved for this pass):* (a) a **non-null `Ref[T]`** wrapper
   type — it needs compile-time non-null-construction analysis (proving a
   `Ref[T]` can never be built from a null `Ptr[T]`) that the enum machinery
   does NOT provide; it is a genuine type-checker addition, not a desugar, so
   it does not fit "cleanly on top of increment 1" and would balloon scope.
   Deferred so the opt-in Optional-deref check lands solidly. (b) **flipping
   `Ptr[T]` to non-null-by-default** — explicitly rejected by design (the
   kernel escape hatch; thousands of call sites assume nullable raw pointers;
   flipping it violates byte-inert-off). Null-safety is delivered as the opt-in
   `!` layer instead.
3. **Descriptive bounds/null trap** (`bounds: idx N of len M at file:line`) + **`@unsafe`
   / `unsafe def`** attribute + `# adder: unsafe` file pragma (small, already designed).

   **STATUS (increment 3 — landed):** All three opt-in / byte-inert-off:
   * **Descriptive trap.** On the FAILING path of a bounds check or a `!`
     None/Err-unwrap under `--check-bounds`, the compiler now writes a
     `bounds: index out of range (len M) at file:line\n` /
     `unwrap of None/Err at file:line\n` diagnostic to fd 2 (stderr) via a raw
     `write(2)` syscall, THEN traps with `ud2` (SIGILL, wait-status 132 — the
     status is unchanged, so the existing bounds/null gates still pass). The
     write is on the COLD, already-branched-away path, so the fast in-range path
     is one `cmp` + a not-taken `jb` exactly as before, and it is byte-inert
     when the flag is off. *Emitted ONLY for the host `x86_64-linux` ELF* (real
     `.rodata` + Linux `write`, run directly on the host so stderr is
     observable). The on-device `x86_64-adder-user` target and the kernel keep
     the compact `ud2` (no message) — this is what preserves the seed<->native
     objdiff byte-lockstep, since native's only userspace target IS adder-user.
     The runtime *index value* N is NOT formatted into the message (it would
     need an out-of-line int→dec routine); the compile-time bound M + the
     file:line site carry the load-bearing "what/where".
   * **`@unsafe` function attribute (chosen surface: the `@unsafe` decorator).**
     A function decorated `@unsafe` suppresses the runtime safety checks in its
     WHOLE body, via the same `unsafe_depth`/`cg_unsafe_depth` counter as the
     `unsafe:` block (composes with nested `unsafe:`; works on free functions
     and methods). Chosen over `unsafe def` because both backends already lex
     `@` + parse a decorator ident chain onto the function node, so it is a pure
     codegen wiring change with no lexer/parser ambiguity. Any decorator other
     than `unsafe` is still rejected by the seed.
   * **`# adder: unsafe` file pragma.** A whole-file comment pragma
     (`^\s*#\s*adder:\s*unsafe\s*$`) marks every function in the TU unsafe. Seed
     scans the main source in the driver; the native `.ad` driver scans the
     merged source buffer. Byte-inert: no production `.ad` carries it.

     *Both backends, byte-lockstep.* Seed: `codegen_x86.py`
     (`_emit_trap_message`, `host_userspace`/`file_unsafe` state, `@unsafe`
     whitelist + body wrap) + `adder.py` (`host_userspace` gate,
     `_source_has_unsafe_pragma`). Native: `codegen.ad` (`cg_file_unsafe`,
     `func_is_unsafe`, body wrap in `gen_function`/`gen_method`) +
     `fused_driver_host_main.ad` (`drv_scan_unsafe_pragma`). objdiff CLEAN on
     the OOB / unwrap / `@unsafe` / pragma fixtures WITH the flag; the descriptive
     message is seed-only (host x86_64-linux), so it never enters the adder-user
     lockstep. Gate: `scripts/test_adder_descriptive_trap.sh`.
4. **`Slice[T]` fat pointers** — dynamic-buffer bounds checks; `Ptr[T]` stays the raw
   escape hatch.

   **STATUS (increment 4 — landed, BOTH backends, byte-lockstep):** A
   `Slice[T]` type: a **16-byte by-reference aggregate** laid out
   `{ ptr: Ptr[T] @0, len: uint64 @8 }` — a base pointer plus a **runtime**
   length, so a dynamically-sized buffer carries its length with it and
   `slice[i]` is bounds-checked against the *runtime* `len` field (unlike
   `Array[N,T]`'s compile-time `N`, and unlike `Ptr[T]`, which stays the raw,
   length-free escape hatch).
   * **Representation / ABI choice.** A Slice is the *same ABI class as a
     struct*: it **decays to its address** and never travels in a single
     register. Adder has no by-value aggregate ABI (increment 1's wall), so a
     Slice is materialised as a 16-byte stack cell and expressions yield its
     address; **passing/returning a Slice by value across a function boundary
     is rejected** (loud error, both backends) exactly like a by-value struct —
     cross-function transfer is via `Ptr[Slice[T]]`. This is the honest answer
     given the ABI, and it reuses the existing struct-storage machinery.
   * **Construction.** `Slice[T](arr)` from an `Array[N,T]` (base `= &arr[0]`,
     `len = N` a compile-time constant) and `Slice[T](ptr, len)` from an
     explicit `(ptr, len)` pair. `Slice` is recognised by **name** (no new
     lexer token → no keyword-collision risk, maximally byte-inert), mirroring
     the `Ptr[T](value)` constructor form.
   * **Indexing / access.** `slice[i]` (load *and* store) emits, under the
     opt-in `--check-bounds` userspace gate, `cmpq %rcx,%rax; jb ok; ud2`
     against the len field (`%rcx = 8(&slice)`), the runtime mirror of the
     Array check; out-of-range traps CLEANLY (SIGILL / wait-status 132) with
     the host-linux descriptive `bounds: slice index out of range at
     file:line` message (adder-user/kernel keep the compact `ud2`, preserving
     the seed↔native byte-lockstep). `.len` / `len(slice)` read the len field;
     `.ptr` reads the raw base pointer. **Byte-inert when off**, **kernel
     structurally exempt** (never emitted on `x86_64-bare-metal`), and
     `unsafe:` / `@unsafe` suppress the check via the shared `unsafe_depth`.
   * **Both backends, byte-lockstep.** Seed (`ast_nodes.py` `SliceType`/
     `SliceNewExpr`; `parser.py`; `codegen_x86.py` `gen_slice_new` /
     `_maybe_emit_slice_bounds_check` / `gen_slice_index_address` + member/len
     paths) and the native `.ad` backend (`parser.ad` `ND_SLICE_TYPE`/
     `ND_SLICE_NEW`; `codegen.ad` `alloc_slice_local` / `gen_slice_index_addr`
     / `emit_slice_new_into` + member/len, composed from the byte-tested emit
     primitives). Gate: `scripts/test_adder_slice.sh`. Verified: slice objdiff
     **5/5 CLEAN**, full-corpus objdiff **256/256, 0 diverged**, fuzzer
     **500/500, 0 miscompiles**, `test_native_kernel_links` PASS,
     `run_compiler_tests` ALL PASS, `build_user` full userland OK, the `-O2`
     bench byte-identical to HEAD (no perf regression), byte-inert-off proven
     HEAD-vs-worktree on both `x86_64-linux` and `x86_64-bare-metal`.

   *Deferred (disproved / honest):* (a) **sub-slicing** (`s[a:b]`) — not this
   pass; the slice type + checked indexing land solidly first. (b) A **bare
   `Slice[T](...)` subexpression** not bound to a local needs an anonymous
   prescan-reserved stack temp on the native path (the seed supports it via
   `gen_slice_new`; native `cg_fail`s and requires binding to a local first) —
   an acceptance gap, not a miscompile, and no corpus uses it. (c) **generics**
   — `T` is carried on the type for element sizing but `Slice[T]` is not a
   monomorphised generic beyond that.
5. **`own T` move-only handles + `drop`** (Tier B) — the biggest Rust-like leap, as a
   compile-time affine check; catches UAF/double-free. Uses the existing `defer`.

   **STATUS (increment 5 — landed; move / use-after-move / double-free core,
   ZERO runtime cost):** A move-only **affine** type qualifier, spelled
   **`Own[T]`** (surface syntax — recognised by NAME like `Slice[T]`, so NO new
   lexer token and NO keyword collision; the bare word `own` collides with real
   identifiers in `drivers/`/`sys/` and was rejected). `Own[T]` is
   **representationally IDENTICAL to a plain `T`** — the parser strips the
   qualifier and yields the inner type, so an `own` binding compiles to bytes
   byte-for-byte identical to a non-`own` one (proven: `Own[int32]` ≡ `int32`,
   `cmp`-identical ELF). The affine analysis is a **compile-time-only** AST pass
   (`adder/compiler/affine_check.py`, run from the seed driver) that emits
   NOTHING at runtime — the kernel and all non-`own` code pay exactly zero.

   *Semantics.* A per-function flow analysis tracks each `own` binding as LIVE
   or MOVED. A binding is **moved** when a bare `own` identifier appears as (a) a
   call/method argument (pass-by-value), (b) the RHS of a binding/assignment, (c)
   a `return` value, or (d) an element of a tuple/list in any of those positions;
   `drop(x)` is just case (a). **Reading a MOVED binding in any position is a
   compile error** ("use after move"); an explicit `drop(x)` moves x so a second
   `drop(x)`/use is caught as a **double-free**. To BORROW without moving, pass
   the address — `foo(&x)` (any non-bare-identifier form) reads x without
   consuming it. **Conditional-move rule:** after an `if`/`match`, a binding is
   MOVED if it was moved on ANY branch (conservative — only ever rejects more,
   never lets a real use-after-move through); re-assigning a moved binding
   revives it; moving an outer `own` binding inside a loop body is rejected
   (double-move across iterations). **Opt-out:** `unsafe:` blocks and `@unsafe`
   functions are not analysed (the escape hatch), matching the runtime-check
   relaxations.

   *Both backends, byte-lockstep.* The SEED (`parser.py` `Own[T]` strip +
   `is_own` on `VarDecl`/`Parameter`; `affine_check.py`; `adder.py`
   `_run_affine_check` hook) is the enforcing oracle. The NATIVE `.ad` backend
   (`parser.ad` `parse_type` `Own[T]`→inner strip) parses `own` **transparently**
   and emits identical code — so seed↔native stay byte-locked on any `own`
   program (objdiff CLEAN on `own_ok`). Gate: `scripts/test_adder_own_move.sh`.
   Verified: the new gate ALL PASS (correct single-move runs; borrow-via-`&`;
   use-after-move rejected; double-drop rejected; seed↔native objdiff clean;
   `Own[T]`≡`T` byte-inert; `@unsafe` opt-out); full-corpus objdiff **256/256, 0
   diverged**; differential fuzzer **500/500, 0 miscompiles**;
   `test_native_kernel_links` PASS; `run_compiler_tests` ALL PASS; `build_user`
   full userland OK; bench binaries **md5-identical to HEAD at `-O2`** (no
   codegen-perf regression); byte-inert-off proven HEAD-vs-worktree on
   `x86_64-linux` (ELF) and `x86_64-bare-metal` (asm).

   *Deferred (honest):* **auto-`drop`-insertion** — emitting `drop(x)` at scope
   exit for an un-moved `own` binding (via the `defer` lowering) is NOT in this
   increment. The high-value core (move / use-after-move / double-free) landed
   solidly first; auto-drop is a follow-up because it (a) would require inserting
   real `drop` calls into the AST that BOTH backends must emit identically — a
   codegen-level change to the native `.ad` backend, not just a seed analysis —
   to preserve lockstep on `own`-using code, and (b) needs a per-binding
   destructor-resolution rule. **Native affine ENFORCEMENT** is also deferred: the
   check is seed-authoritative this pass (it emits no bytes, so lockstep is
   unaffected); porting the per-function flow analysis into the 14.7k-line
   `codegen.ad` is a separate effort with no byte impact. The native backend
   already accepts `own` syntax byte-transparently.
6. **Region/arena lifetimes** (long-horizon) — scoped "ref can't outlive region."
7. **App-ergonomics sugar** (interleaved): default/keyword args, string methods, richer
   `match` (exhaustiveness warnings), closures that capture env, a small app std-lib
   (collections/strings/io), integer-overflow-checked arithmetic opt-in.

   **STATUS (increment 7a — landed, BOTH backends, byte-lockstep): DEFAULT
   PARAMETER VALUES + KEYWORD ARGUMENTS.** The two highest-daily-value items
   from the list, sharing one clean mechanism (call-site normalization). A
   DIRECT call to an in-unit `def` may now:
   * **omit trailing arguments** — filled from the parameter's declared
     default: `def f(x: int32, y: int32 = 10)`; `f(5)` desugars to `f(5, 10)`;
     and/or
   * **pass arguments by name** — `f(y=2, x=1)`, in any order, mixed with
     leading positionals (`scale(3, factor=4)`).

   *Desugaring approach.* Pure **call-site normalization** — no ABI change, no
   runtime cost. At each direct call to a known function, kwargs are bound to
   parameter positions by name and every unfilled slot is filled from its
   parameter's default expression, producing a plain positional argument list
   that flows through the existing SysV marshalling unchanged. The default
   expression AST is spliced **read-only** into the callee's argument slot (both
   backends emit the same node), so no aggregate/heap machinery is involved and
   the representation is identical to writing the call out longhand.

   *Byte-inert when unused.* A call that already supplies every argument
   positionally takes the fast path and emits bytes **identical to HEAD** — the
   seed returns `call.args` unchanged; the native backend leaves the normalization
   flag 0 and walks the original arg chain. Proven: a fully-explicit call site is
   byte-for-byte identical whether or not the callee declares a trailing default.
   Existing code declared no defaults (the seed rejected them before this
   increment), so no production `.ad` moves a byte.

   *Both backends, byte-lockstep.* SEED (`codegen_x86.py`: `func_params` table +
   `_normalize_call_args`, called at the top of `gen_call`; the FunctionDef
   default-param rejection replaced by a trailing-default-ordering check).
   NATIVE (`codegen.ad`: `find_prog_function` + `normalize_call_args` pushing a
   **re-entrant window** onto `norm_stack` — a nested normalized call inside an
   argument expression pushes/pops its own window — consumed by `gen_call`; plus
   the same trailing-default check in `gen_function`). The parser already parsed
   both surfaces (defaults on `Parameter`/ND_PARAM.b, kwargs as an ND_ASSIGN in
   the arg chain), so no lexer/parser or new-keyword change — maximally byte-inert.
   Gate: `scripts/test_adder_app_sugar.sh`.

   **STATUS (increment 7-tail — the foundational `String` type, SEED backend,
   landed):** the deferred "needs a heap-backed string type" blocker below is
   now addressed by a `String` VALUE type: a 16-byte `{ptr@0, len@8}`
   by-reference aggregate VIEW (representationally a `Slice[uint8]`, same ABI
   class — decays to its address, crosses fn boundaries only via `Ptr[String]`,
   Adder has no by-value aggregate ABI). Construction `String("literal")`
   interns the bytes into `.rodata` (NUL-terminated, so `.cstr` round-trips
   straight back to the raw `Ptr[uint8]` C-string world); `String(ptr, len)` is
   the caller-owned-buffer / substring form. Accessors: `.len` (byte length,
   no NUL scan), `.ptr`/`.cstr` (Ptr[uint8]). The core methods live in
   `lib/strview.ad` as ORDINARY Adder over raw `(ptr, len)` pairs — `str_eq`,
   `str_find`, `str_contains`, `str_at` (substring-view helper), and
   `str_concat_into` (concat into a **caller-owned** buffer) — so they compile
   through the byte-tested path and are seed<->native byte-lockstep for FREE
   (objdiff clean, no new codegen). USERLAND-only: `String` is pure pointer
   math with ZERO runtime, so the kernel keeps raw `Ptr[uint8]` and pays
   nothing (byte-inert-off; the native backend carries no String code at all, so
   every String-free unit is byte-identical to base). Gate:
   `scripts/test_adder_string.sh` (behaviour checksum 42, on-device +
   kernel-safe, helper-layer lockstep, native-rejects-String cleanly).

   *Design finding — no owning heap-String (disproof, evidence-backed):* a TRUE
   *owning* heap string (per-string small allocations, growable `+`) is
   **blocked** — the Adder userland has NO general-purpose allocator. The only
   primitives are page-granular `sys_mmap` (an extern syscall wrapper, 4 KiB
   minimum) and the kernel's `kmalloc`; userland code uses fixed `Array`s. The
   brief forbids inventing an allocator or dragging a heap runtime into the
   kernel, so `String` is deliberately a length-carrying VIEW over caller-owned
   storage (exactly how `Slice[T]` relates to `Array[N,T]`), and concatenation
   writes into a caller-provided buffer. That is the codebase-consistent,
   invariant-honoring foundational type; an owning `String` awaits a real
   userland allocator (a std-lib increment, not a compiler one).

   *Deferred (honest):* (a) **native `String` backend** — this increment is
   SEED-first (like increment 1 was); `codegen.ad` REJECTS a `String`-typed
   source with a clean codegen error (no ELF, no miscompile), pending the
   native port of the construction/member emission. (b) **method-call sugar**
   (`s.eq(t)` / `s.find(t)`) over the free-function form — desugaring
   aggregate-receiver method calls in both byte-lockstep backends is a
   follow-up; the free functions ship the capability today. (c) `.upper()`/
   `.split()`/`.replace()` and formatting — std-lib helpers atop this base.

   *Superseded note:* (a) **string methods** — `.upper()/.split()/.replace()`
   etc. need a heap-backed string type; Adder strings are raw `Ptr[uint8]` today,
   so this is a std-lib/representation increment, NOT a cheap byte-inert desugar.
   (b) default/keyword args on **methods** and **externs** — methods route
   through `MethodCallExpr` (never `gen_call`) and externs have no visible body;
   both keep the pre-existing "default params unsupported" rejection. (c)
   `*args`/`**kwargs`, closures capturing env, integer-overflow-checked
   arithmetic, and the app std-lib — future passes.

   *Increment 7-tail follow-up — userland heap allocator (landed, LIBRARY, no
   compiler change):* the "owning `String` awaits a real userland allocator"
   blocker above is now UNBLOCKED. `lib/hamalloc.ad` is a pure-Adder
   general-purpose heap — `ham_alloc(nbytes)` / `ham_free(ptr)` /
   `ham_realloc(ptr, nbytes)` — built ENTIRELY over the existing
   `sys_mmap`/`sys_munmap` page primitives (no new syscall, no compiler
   change, no kernel wiring). Design: segregated LIFO free-lists over a fixed
   set of 16-byte-multiple size classes (16 … 2048) carved from `sys_mmap`'d
   256 KiB page arenas that grow on demand; a 16-byte boundary header
   (size + magic-tagged class/kind) gives O(1) alloc/free, 16-byte-aligned
   payloads, and magic-guarded double/wild-free refusal. Requests > 2048 B are
   served by a direct page-rounded `sys_mmap` and returned to the OS via
   `sys_munmap` on free. Freed small blocks are always reused by a later
   same-class alloc, so a bounded working set under churn never grows the
   mapped footprint — proven by `scripts/test_adder_hamalloc.sh` (on-device
   QEMU): alloc/readback + non-overlap, free-then-alloc reuse, alignment across
   every class, realloc grow+preserve, large mmap/munmap, and a 20k-cycle
   stress that verifies a per-block pattern on every free and asserts a bounded
   footprint after warm-up. Because it is plain Adder over existing primitives
   it is seed↔native objdiff-clean by construction. This is the std-lib
   foundation an owning heap `String` / dynamic vector / map can now build on.

   *Increment 7-tail payoff — owning-heap String METHODS (landed, LIBRARY, no
   compiler change):* the app-ergonomics layer real programs reach for, built
   as `lib/hamstr.ad` — a PURE LIBRARY composing the two layers above
   (`lib/hamalloc.ad` mints/owns bytes, `lib/strview.ad` searches/sub-slices
   without copying) with NO compiler change. Every function carries the raw
   `(ptr, len)` / `Ptr[uint8]` ABI — never a `String` aggregate — so the native
   `.ad` backend accepts it exactly like hamalloc and it is seed↔native
   byte-lockstep (objdiff clean; 49 functions match). Methods + ownership:
     * `ham_str_upper/lower(src,len)` — ASCII case fold; owning copy.
     * `ham_str_trim(src,len)` — strip leading/trailing ASCII whitespace; owning.
     * `ham_str_replace(src,len, needle,nlen, repl,rlen)` — all non-overlapping
       occurrences (longer- or shorter-than-needle); owning.
     * `ham_str_from_int(n)` / `ham_str_from_uint(n)` — integer→decimal; owning.
       Correct for zero, negatives, and INT_MIN (magnitude via unsigned negate)
       and UINT64_MAX. First way to stringify a number in userland Adder.
     * `ham_str_starts_with/ends_with(...)` — non-owning view predicates.
   Every owning return is a fresh NUL-terminated allocation the CALLER frees
   with `ham_str_free`; null on OOM. **split** cannot return a `String[]` (no
   by-value aggregate return, no dynamic array-of-String yet), so it is exposed
   as a ZERO-ALLOCATION stateful iterator `ham_split_next(src,len,sep, &pos,
   &fptr, &flen)` yielding each field as a non-owning VIEW into the caller's
   buffer (N separators → N+1 fields, empties included) — the allocation-free
   shape a `for f in s.split(sep)` desugars to; a `String[]` return awaits a
   dynamic-array aggregate ABI. Gate: `scripts/test_adder_hamstr.sh` (on-device
   QEMU) asserts every method against expected output (incl INT_MIN/UINT64_MAX,
   empty-needle no-op, trailing-sep, all-whitespace trim), frees each result,
   and churns 2000 allocations to prove the heap is uncorrupted after the frees.

Each increment: opt-in or byte-inert-off, kernel-bypassable, seed+native lockstep,
verified by objdiff + differential fuzzer + `test_native_kernel_links` +
`run_compiler_tests` + a new feature gate.
