# Adder — the Language & Compiler

> **Source of truth:** `adder/compiler/` (`compiler/` is a symlink to it),
> `adder/LANGUAGE.md`, `adder/scripts/`, `adder/tests/`
> **Last verified against source:** 2026-06-10
> **Backend rationale:** [../x86-backend.md](../x86-backend.md)
> **Language reference:** [../../LANGUAGE.md](../../LANGUAGE.md) (symlink into `adder/`)

## Purpose

**Adder** is the systems language Hamnix is written in: Python syntax,
static types, compiled by a **hand-written compiler with no LLVM**. The
compiler emits x86_64 (and AArch64) assembly directly. It is inlined
in-tree under `adder/` (no longer a git submodule, since commit 9a8801e).
Source files end in `.ad`.

## Key files

| Path | Role |
|--|--|
| `adder/compiler/adder.py` | the driver: `compile_source`, `compile_with_imports`, `main` — whole-program build entry |
| `adder/compiler/lexer.py` | tokenizer |
| `adder/compiler/parser.py` | recursive-descent parser → AST (`Parser`, `parse`, `parse_with_errors`) |
| `adder/compiler/ast_nodes.py` | AST node definitions |
| `adder/compiler/codegen_x86.py` | the x86_64 SysV AMD64 backend (`X86CodeGen`, `generate`) — hand-written encoder |
| `adder/compiler/codegen_arm64.py` | the AArch64 backend |
| `adder/compiler/optimizer.py` | optimization passes |
| `adder/compiler/elf_emit.ad` | ELF emission |
| `adder/compiler/*_selftest.ad`, `*_test.py` | in-tree self-tests |
| `adder/LANGUAGE.md` | the language reference (also at repo root `LANGUAGE.md`) |
| `adder/scripts/test_compiler_*.sh` | per-feature compiler regression tests |

(There are dual `.py` and `.ad` versions of `lexer`/`parser` — the `.py`
is the bootstrap host compiler; the `.ad` versions are the self-hosting
track, where Adder compiles its own compiler.)

## Architecture & data structures

Pipeline: source `.ad` → `lexer.py` → `parser.py` (→ `ast_nodes.py`) →
`optimizer.py` → `codegen_x86.py` / `codegen_arm64.py` → assembly →
ELF (`elf_emit.ad`). The driver `adder/compiler/adder.py` does
whole-program builds via `compile_with_imports(main_file, target)`.

`X86CodeGen` (`codegen_x86.py:253`) carries `LocalVar`, `StructInfo`,
`LoopContext`, `FunctionContext` to track frames, struct layouts, and
control flow; `generate(program, bare_metal)` is the top-level emit.

**Targets** (the `target=` flag / `bare_metal`):

| Target | Output |
|--|--|
| `x86_64-bare-metal` | `hamnix-kernel.elf` (higher-half kernel) |
| `x86_64-adder-user` | CPL-3 user ELF (the `user/` binaries) |
| `x86_64-linux-kernel-module` | a stock-Linux-shape `.ko` (for the L-track regression) |
| (AArch64 variants) | via `codegen_arm64.py` |

Kernel codegen honors SysV AMD64, 16-byte stack alignment, `ENDBR64`
(IBT), no red zone, RIP-relative `.rodata` (see
[../x86-backend.md](../x86-backend.md)).

## Entry points

- `adder/compiler/adder.py` `main()` — CLI; `compile_with_imports(main, target)`.
- `parse(source, filename)` (`parser.py:1419`) — source → AST.
- `generate(program, bare_metal)` (`codegen_x86.py:3866`) — AST → asm.

## Invariants & gotchas

- **No LLVM.** The backend is a hand-written encoder; codegen bugs are
  fixed *in the compiler* + a regression fixture in `tests/` /
  `adder/scripts/test_compiler_*.sh`, never worked around at the call
  site (project working-agreement).
- Compiler quirks are tracked in the orchestrator's
  `memory/feedback_compiler_quirks.md` (not in-repo); e.g. adjacent
  string-literal concatenation is unsupported.
- Keep the language **simple**: prefer a minimal language extension over a
  kernel-side workaround when an idiom is awkward.
- `compiler -> adder/compiler` is a symlink; edit under `adder/`.

## Self-hosting parity gate (`codegen.ad` vs `codegen_x86.py`)

The Python backend (`codegen_x86.py`) is the **bootstrap seed** (correct,
optimizer frozen). The Adder backend (`codegen.ad`) is the **product** and
must reach full parity to drive the build self-hosted. Two host-only gates
(NO QEMU, NO image build) enforce this:

- `scripts/fuzz_adder.sh` — the predicted-output oracle over the Python
  backend; 0 miscompiles is the floor.
- `scripts/fuzz_adder_diff.sh` (`--ad-codegen`) — runs the `codegen.ad`
  pipeline ON THE HOST (a `--target=x86_64-linux` driver dumps its
  machine-code + data bytes; `tests/fuzz/ad_codegen_host.py` wraps them in a
  real ELF and runs it) and compares against the same oracle. Reports
  accept-rate + correctness-rate; nonzero only on a genuine `codegen.ad`
  miscompile.

**Construct coverage in `codegen.ad`:** 1-D/2-D/scalar globals of every
width (signed/unsigned, `.data`/`.bss`), casts (narrowing truncation +
widening extension), compares, div/mod (signed/unsigned), while-loops,
if/elif/else, break/continue, pointers, syscalls, helper calls.
**Multi-dimensional array globals** (`Array[N, Array[M, T]]`) index
level-by-level: each global carries its array type node (`glob_type_node`),
the outer index scales by the nested row stride (`type_size_of(element)`)
and the inner by the scalar element; the index-scale helper has an `imulq`
fallback for non-power-of-2 strides. As of this work the differential
generator emits identical traffic in subset and default mode (subset ==
default), so the gate exercises every construct the product backend must
handle.

**Track-3 self-hosting parity (structs / classes / loops) — LANDED.**
`codegen.ad` now mirrors `codegen_x86.py` for:

- **Structs / member access.** `layout_struct` builds an 8-byte-rounded
  C-ABI field layout (each field aligned to `natural_align`, capped at 8;
  inheritance prepends base fields left-to-right transitively). Struct
  table = `st_*` arrays + a flat `sf_*` field table. Locals carry a
  struct-table index (`loc_struct_idx`, with `loc_struct_is_ptr` for the
  `Ptr[Struct]` `self` receiver); globals carry `glob_struct_idx` (an
  in-place `.bss` value of `total_size` bytes). `gen_member_address`
  computes `&obj + field_offset` for an in-place value, or `(loaded ptr
  value) + field_offset` for a `Ptr[Struct]` — exactly
  `gen_member_address`/`_obj_is_pointer`. `gen_member_load` does a sized
  load of the field width (array/embedded-struct fields decay to their
  address); `gen_assign_member` does the sized store + augmented
  read-modify-write. `emit_add_imm_rax` matches GNU `as`' imm8/imm32 add
  encoding choice for the field offset.
- **Classes / methods / construction.** A method `def m(self, …)` is
  emitted as a free function (`gen_method`) with an implicit first arg =
  the receiver address; its mangled identity is the `(owner-class name,
  method name)` pair (the `Class__method` symbol), resolved via a separate
  method-symbol table (`mfn_*`) + method-call fixups (`mfx_*`). `obj.m(args)`
  (`gen_method_call`) resolves the owning class (own-then-base first-match,
  mirroring `class_methods`) and passes `&obj` (or the pointer value) as
  arg0. `f: Foo = Foo(args)` (`gen_ctor_init`) lowers to `Foo__init(&f,
  args)`. The `self` param + every `self` reference are matched by the
  parser's `nd_aux==1` marker (not by name), via `cg_self_off`/`cg_self_struct`.
- **For-loops + do-while.** `gen_for` lowers `for v in range(start, stop,
  step)` to a counter loop (compile-time loop direction from a constant
  negative step) and `for v in <array>` to a hidden-index walk binding `v`
  to a private element copy; `continue` lands on the induction step (not
  the top), matching `LoopContext`. `gen_do_while` runs the body once then
  a `jnz`-back conditional test; `continue` targets that test. Both reuse
  the existing loop-frame break/continue machinery.

The struct fixed-32 differential is value-based (not byte-identical) so
`codegen.ad` is free to pick its own register/encoding within each lowering
as long as the runtime value matches the oracle. **Remaining for a
default-build cutover:** multi-base receiver-offset bump, by-value embedded
struct fields, struct-typed params/returns by value, `for`-over-`Ptr[T]`.
Floats are now DONE (see below).

### Floating point — scalar SSE, LOCKSTEP (DONE 2026-06-21)

Floats are implemented in BOTH backends **in lockstep**, plus the fuzzer's
bit-exact oracle, so the differential gate stays valid. (The earlier
"parity blocker" finding — that the seed had ZERO FP and a `codegen.ad`-only
impl couldn't be fuzz-proven — is resolved: the seed was extended with FP as
a missing CORRECTNESS feature. The "FROZEN" rule covers only the OPTIMIZER,
which is untouched.)

**Transit model (both backends).** A `float32`/`float64` VALUE travels through
the same single-accumulator path as every integer — it lives in `%rax` as its
raw IEEE-754 **bit pattern** (float32 in the low 32 bits). All existing spill
(`pushq %rax`), sized local store/load, GP-register parameter passing, and
`%rax` return scaffolding therefore moves floats correctly for free. SSE
registers (`%xmm0`/`%xmm1`) are used ONLY at the instant an FP op runs: the op
loads the bits from `%rax`/`%rcx` (`movd`/`movq`), runs the scalar SSE
instruction, and moves the result bits back to `%rax`. Eval/spill order is
byte-identical to the integer `gen_binary` path.

**Mechanisms (mirrored byte-for-byte):**

- `FloatLiteral` -> constant in the `.rodata`/data literal pool, loaded as
  bits. (`codegen.ad`'s frontend only preserves a float literal's integer
  part, so it materializes the integer and `cvtsi2sd`s it; the fuzzer derives
  all floats from integers, so fractional literals never reach either backend.)
- `float32`=4 / `float64`=8 in the type-size tables; per-local `loc_is_float`
  and per-global `glob_is_float` markers (mirroring `_float_width(
  get_expr_type)`) distinguish a float32 from an int32 (both scalar_size 4).
- Arithmetic: `addss/subss/mulss/divss` (+ `sd`). Operand promotion to the
  wider float width in a mixed binop; an integer operand `cvtsi2`-promotes.
- Compares: `ucomiss/ucomisd` -> `setcc`, with a parity guard
  (`setnp`/`setp` + `andb`/`orb`) so a NaN-unordered compare yields the IEEE
  result (`==,<,<=,>,>=` false; `!=` true).
- Conversions: `cvtsi2ss/sd`, `cvttss/sd2si` (truncate toward zero),
  `cvtss2sd`/`cvtsd2ss`. A float->int cast leaves a 64-bit signed int that the
  integer narrowing fix-up then truncates for sub-8-byte int targets.
- Unary negate: sign-bit XOR (`xorl $0x80000000,%eax` / `xorq` with the 64-bit
  sign mask), so `-0.0` is produced correctly (not an integer `neg`).

**Validation.** The fuzzer (`tests/fuzz/adder_fuzzer.py`, `_gen_float_traffic`)
emits FP decls + arithmetic/compare/convert/negate traffic in BOTH subset and
default mode (identical rng stream). FP results fold into the `uint64 g_accum`
oracle BIT-EXACTLY: every float value is integer-derived (`cast[floatN](int)`)
and every fold truncates back to `int64` then widens to `uint64`; float32 uses
a `FloatType` model that rounds through IEEE single so the oracle equals the
SSE register value, and divisions are chosen to yield exact quotients (no
rounding ambiguity). `scripts/fuzz_adder_diff.sh --ad-codegen` over 4 seeds ×
400 (1600 programs) = **100% accepted, 100% correct, 0 miscompiles, 0
unsupported**, with float traffic flowing through both backends; the Python
fuzzer over 1500 programs is clean; the `regress_codegen.ad` pin is unchanged.

**ABI note (the one remaining FP gap).** This backend passes args in the GP
register/stack sequence for ALL types (integer included), not the SysV
INTEGER+SSE class split. That is internally consistent across both Adder
backends — which is exactly what the differential fuzzer validates — but a
call to a TRUE SysV extern taking `float`/`double` in `XMM0-7` is not yet
wired (the fuzzer makes no such call). ARM64 FP is left as-is (not required
for the x86 cutover).

## Related docs

- [../x86-backend.md](../x86-backend.md) — why hand-written, codegen contract.
- [../../LANGUAGE.md](../../LANGUAGE.md) — the language reference.
- [build-test.md](build-test.md) — how the compiler is invoked by the build.
- [arch-arm64.md](arch-arm64.md) — the AArch64 backend's target.
