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

**Sub-8-byte LOCAL stores are SIZED (`movl`/`movw`/`movb`) — cutover
keystone.** An assignment into a sub-8-byte scalar LOCAL must truncate to the
slot's declared width, exactly like `codegen_x86._emit_local_store`.
`store_to_named` now consults `lookup_local_scalar_size` and emits
`emit_store_local_rax_sized(off, width)` (movl/movw/movb) instead of a blind
8-byte `movq`. This was the LAST self-hosting-cutover miscompile: the whole
image built with `ADDER_CC=adder` booted to PID-1 init but every
`execve` failed with `kmalloc: request 67108864` — the native backend stored
a uint32 file-size local with a non-truncating `movq`, so the misread size
overflowed bit 31, got clamped to `_NS_BLOB_MAX` (67108864 = 64 MiB), and the
64 MiB `kmalloc` exceeded `MAX_ORDER`. The divergence was localized by
objdump-diffing `fs/vfs.ad`/`fs/tmpfs.ad` exec-path functions (seed `movl`
stores vs native `movq`). Behavioral + emission regression:
`scripts/test_local_store_trunc.sh` (fixture
`tests/fuzz/regress_local_store_trunc.ad`, seed-oracle exit 85; pre-fix
native exits 0).
**Sub-8-byte PARAMETER spills are SIZED + >6-arg STACK spills handled —
cutover follow-on (2026-06-22).** The prior local-store fix covered only
assignment into a named LOCAL; the parameter-SPILL path (`spill_params`, called
from `gen_function`/`gen_method`) still emitted a blind 8-byte `movq` for EVERY
param via `emit_spill_arg`. Now it mirrors `codegen_x86.gen_function`'s spill
pass exactly: a sub-8-byte scalar param is tagged with its declared width
(`loc_scalar_size`, sign-AGNOSTIC like the seed's `_scalar_local_size`, so a
`float32` param — `type_signedness`==0, which the old gate skipped — is sized
too) and spilled SIZED (`emit_spill_arg_sized` → movb/movw/movl, with r8d/r9d
REX), so the slot does not keep the arg register's high garbage. A function with
MORE THAN 6 params now loads args 7+ from the STACK (`16+(i-6)*8(%rbp)`) and
stores them sized — the old `emit_spill_arg` `else` branch re-spilled r9 into
every arg-index≥5 slot, so a >6-param callee read the 6th arg (or garbage) for
params 7+. Byte-verified equal to the seed's spill region for mixed-width and
>6-param functions. Floored by `scripts/test_param_spill_trunc.sh` (fixture
`tests/fuzz/regress_param_spill_trunc.ad`, seed-oracle exit 214) + the
fuzz/whole-tree gates (194 units unchanged, 0 miscompiles over 2000 programs).

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
as long as the runtime value matches the oracle.

**Multi-base receiver-offset bump — LANDED (2026-06-21).** When a method is
inherited from a NON-FIRST base (e.g. `class D(A, B)` calling `B`'s method on
a `D`), the receiver pointer must be bumped by `sizeof(prior bases)` so the
callee's `self.field` addressing (against the owner's layout, which starts at
offset 0) lands on the right bytes. `codegen.ad` now computes this with
`class_end_of_fields()` (a flattened field walk WITHOUT the trailing 8-byte
`.bss` round-up — mirrors `_collect_class_methods.end_of_fields`) and
`receiver_offset_for()` (the running offset where the owning base sits —
mirrors `resolve`'s `running_offset`), then `gen_method_call` emits an
`emit_add_imm_rax(recv_off)` bump. Single inheritance / own methods stay at
offset 0 (no bump), bit-identical to before. The fuzzer emits a
`MDerived(MBase0, MBase1)` class with a method inherited from the SECOND base
(receiver_offset 16), folded bit-exactly into `g_accum`, so the gate exercises
the bump on every program.

**By-value struct params/returns — REJECTED IN LOCKSTEP (2026-06-21).** Adder
has NO by-value aggregate ABI by design (see the table below: aggregates cross
function boundaries via `Ptr[T]` out-parameters). The Python seed previously
*silently miscompiled* a struct-typed param (it spilled one arg register and
read the rest as stack garbage) and returned a dangling local address for a
struct return. Fixed at the right layer: BOTH backends now REJECT a by-value
struct parameter or return type LOUDLY — the seed with a `CodeGenError`
("pass `Ptr[T]` … Adder has no by-value aggregate ABI"), `codegen.ad` with
`cg_fail(9)` in `gen_function` (param loop + the `nd_b` return-type check).
This closes the parity gap correctly (both refuse) and removes a latent
silent-miscompile. The self-hosted toolchain (`lexer.ad`, `parser.ad`,
`codegen.ad`, `elf_emit.ad`) uses ZERO by-value structs, so this is not a
self-hosting fixpoint blocker.

**SysV XMM FP-arg convention — intentionally GP-uniform (documented).** No
`extern def` with a float param exists anywhere in the `.ad` tree, and the
fuzzer passes every argument (including float-typed values, which travel as
their IEEE-754 bit pattern in a GP register) through the GP arg sequence
self-consistently. Both backends are therefore GP-uniform for calls and need
NO XMM arg path. A true SysV extern taking a `float`/`double` would need the
value class-routed into `%xmm0..7` (and the return read from `%xmm0`); the
single place this would hook in is `codegen_x86.gen_call`'s arg-marshal loop
(and the mirror in `codegen.ad`'s `gen_call`). Not wired because nothing
exercises it. Floats within Adder code are DONE (see below).

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

## Self-hosting cutover — BINARY-DIFFERENTIAL SWEEP, real-userland miscompiles fixed (2026-06-22)

The fuzz dry-run proved equivalence on a NARROW language subset; the real
question — does `host_ac.elf` emit BEHAVIORALLY-equivalent code for the ACTUAL
production userland? — is answered by a SYSTEMATIC native-vs-seed machine-code
differential over EVERY accepted unit, not boot-debugging one at a time.

**Harness — `scripts/test_native_vs_seed_objdiff.sh` + `scripts/objdiff_normalize.py`.**
Compiles every `user/*.ad` unit with BOTH backends (seed = Python oracle via
`as`/`ld`; native = `host_ac.elf`), disassembles each as raw x86-64 (the bytes
ARE x86-64; the ELFCLASS32 is only for the Hamnix loader), aligns functions
(global score-ordered histogram match — the seed's symtab order and native's
emission order differ for merged multi-TU UI units), and flags REAL semantic
divergences (wrong operand WIDTH, opcode class, register, missing/extra ops)
while NORMALIZING the documented encoding freedoms: register-allocation /
push-pop spills, load-folded sign-extends, the seed-only stack-protector,
stack-arg marshalling (`mov %r,(%rsp)` vs `push`), power-of-2 index scaling
(`imul $n` vs `shl`), immediate materialization (`movabs` vs sign-extending
`movq $imm32`), and sub-8-byte frame reloads. **Result: ZERO semantic
divergences across all 193 accepted userland units.**

**The pid-7 boot-blocker — FIXED (the keystone).** `etc/rc.boot`'s first
external command is `cat /etc/installer-medium` (rfork'd as pid 7). The native
`_start` stub in `elf_emit.ad` (`elf_emit_image`) emitted `mov $entry_arg,%edi;
call main` — hardcoding a constant as main's FIRST arg. But the Hamnix user ABI
passes **argc in %rdi, argv in %rsi IN REGISTERS** (kernel pre-loads them before
sysretq; see `user/runtime.S`'s `_start`). The stub CLOBBERED %rdi (argc) with
0, so a real `cat FILE` ran `main(0, …)`, took the argc<2 branch, and hung
reading stdin during boot — the immediate freeze on entry `0x57f`. Fix: the stub
now leaves %rdi/%rsi untouched and forwards them to main, mirroring runtime.S
exactly (`call main; movslq %eax,%rdi; mov $1,%rax; syscall; jmp .`).

**Real-userland miscompile classes the sweep found + fixed in `codegen.ad`
(each floored in `tests/fuzz/adder_fuzzer.py`):**

- **Logical `and`/`or` NON-short-circuit.** `codegen.ad` lowered `BINOP_AND`/
  `BINOP_OR` as a bitwise fold (bool-ify BOTH operands, then `and`/`or`) —
  evaluating the RHS unconditionally. The frozen seed (`gen_binary` ->
  `gen_short_circuit`) short-circuits (Python/Adder semantics). A non-short-
  circuit `p != 0 and p[i] != 0` DEREFERENCES a null pointer; every `streq`'s
  `while a[i] != 0 and b[i] != 0` over-read. Fixed with the exact
  `gen_short_circuit` branch chain. (~63 units.)
- **Compare/shift/div SIGNEDNESS for non-IDENT operands.** `expr_signedness`
  resolved only `ND_CAST`/`ND_IDENT`, returning 0 (unknown -> SIGNED default)
  for `ND_INDEX` (array/ptr element), `ND_MEMBER` (struct field), `ND_CALL`
  (return type), and reported every **8-byte** global as unsigned. The seed's
  `get_expr_type` resolves all of these. Result: unsigned arrays used signed
  `setl`/`sar` (base64 `quad[i]>>n`, nproc/uptime `buf[j]>=48`), int64 globals
  used `div`/`xor` instead of `idiv`/`cqto` (hamcalc `acc/operand`), a
  `Ptr[uint8]` param used signed compare (join `a[i]<c[k]`), a uint64 call
  result used signed compare (hdu `cursor+1 < total_rows()`). Fixed by extending
  `expr_signedness` to `ND_INDEX` (`index_elem_signed`, + recording `loc_type_node`
  for named `Ptr[T]` locals/params), `ND_MEMBER` (`member_scalar_signedness` via
  a new `sf_signedness` field table), `ND_CALL` (`call_return_type`), and an
  8-byte-global tristate (`glob_signedness`). (~100 units.)

**Whole-tree + kernel still green:** the whole-tree gate keeps acceptance at
194 units; `test_selfhost_kernel_elf.sh` PASSES (host_ac codegens the full
326 K-line kernel closure and `ld`-links a bootable higher-half ELF). NOTE: the
8-byte-global fix added `glob_signedness`, which MUST also be in
`concat_compiler_source.py`'s `HOST_BUFFER_OVERRIDES` (scaled to 16384) — else
the kernel's ~9,266 globals overflow the on-disk `Array[1024]` and corrupt
codegen `.bss` (a regression caught only by the kernel-elf gate, NOT by
userland objdiff). Every new whole-tree-sized `glob_*` array needs the override.

## Self-hosting cutover — PARITY-COMPLETE + dry-run PROVEN (2026-06-21)

All `codegen.ad`-vs-seed correctness gaps that the differential fuzzer can
reach are closed (multi-base offset LANDED; by-value struct ABI REJECTED in
lockstep; XMM extern documented as GP-uniform/unused). The self-hosted `.ad`
compiler is **cutover-ready**: it builds as a host binary and reproduces the
seed across the corpus.

**Dry-run result (host-only, no QEMU).** `scripts/test_selfhost_cutover_dryrun.sh`:

1. Fuses `lexer.ad + parser.ad + codegen.ad + elf_emit.ad +
   `fused_driver_host_main.ad`` (a Linux-syscall, argv-driven driver — the
   host twin of `fused_driver_main.ad`) into one source via
   `concat_compiler_source.py` and compiles it with the **Python seed** to a
   single static `x86_64-linux` ELF (`build/cutover/host_ac.elf`, ~272 KB).
   It links and runs; a smoke compile succeeds. (Its EMITTED ELF is a
   Hamnix-format ELF32 image — `elf_emit.ad` deliberately writes
   `ELFCLASS32`/`EM_386` for the Hamnix `fs/elf.ad` loader — so it is NOT run
   on host Linux here; the on-device `test_selfhost_fixpoint.sh` runs it.)
2. **Differential self-compile** (`tests/fuzz/cutover_dryrun.py`): over the
   fuzz corpus, each program is compiled by BOTH the Python seed
   (`codegen_x86.py` → `as`/`ld`) AND the self-hosted `.ad` host compiler
   (the `ad_codegen` dump driver = `lexer.ad+parser.ad+codegen.ad` fused to
   `x86_64-linux` by the seed), then run; the two are asserted
   behaviorally-identical (same printed `g_accum` + exit). **300/300 = 100%
   match, 0 mismatch, 0 unsupported.** (Not byte-identical by design: the
   seed routes through GNU `as`, `codegen.ad` emits raw machine code —
   different-but-equivalent encodings.)

There is **no self-hosting fixpoint blocker**: the `.ad` compiler's own
source uses only the flat SoA subset (parallel global arrays, `Ptr[T]`,
`Array[N,T]`) that both the seed and `codegen.ad` already compile — zero
classes, zero by-value structs.

### Self-hosting cutover — WHOLE-TREE blocker (2026-06-21)

**The fuzz dry-run is NOT sufficient to flip the default build driver.** The
fuzzer generates only a narrow language subset. The real question — *can
`host_ac.elf` compile the actual production tree?* — is answered by the
**whole-tree differential** gate, `scripts/test_selfhost_wholetree_diff.sh`,
which compiles every real userland `.ad` unit with BOTH backends:

**Capability #1 (extern linkage) — LANDED 2026-06-21.** Before→after:

```
                                         BEFORE       AFTER (extern linkage)
real userland .ad units:        211          211
  single-TU (0 imports):        128          128
  multi-TU (imports):            83           83
Python seed (oracle) accepted:  128 / 128    128 / 128   (100%)
.ad host compiler accepted:       2 / 128    119 / 128
  rejected — reason 7:           120            3   (insmod/modprobe/rmmod — inline asm_volatile)
  rejected — reason 8:             6            6   (init, shuf, vi, useradd, getty, umdf_host)
```

The whole-tree differential gate (`scripts/test_selfhost_wholetree_diff.sh`)
floored the `.ad`-accepted baseline at **119/128** single-TU units after
CAP#1 (since raised to 129/211 by CAP#2 — see below), and a behavioral gate
(`scripts/test_selfhost_extern_link.sh`) proves the synthesized wrappers issue
runtime.S's exact syscall numbers (381 wrapper instances across 117 units
verified). The remaining 3 reason-7 units (`insmod`/`modprobe`/`rmmod`) are
NOT an extern-linkage gap — they use inline `asm_volatile`, which surfaces as
an unresolved `asm_volatile` "callee"; that is a NEXT-capability construct.
After CAP#1, three cutover capabilities remained; **CAP#2 (import resolution)
has since LANDED**, leaving ELF-formats (#3) and reason-8 constructs (#4).

The `.ad` compiler (`codegen.ad` + `elf_emit.ad` + the fused driver) is a
**closed-world, single-translation-unit subset compiler**. The remaining
load-bearing capabilities are:

1. **Extern linkage — DONE (was reason 7, the dominant blocker).**
   Real userland units declare `extern def sys_write(...)` etc.; the seed
   satisfies those by assembling + linking `user/runtime.S` (and, for the
   kernel, the boot stubs `arch/x86/boot/header.S`, `arch/x86/kernel/head_64.S`
   under `arch/x86/kernel/kernel.lds`). `codegen.ad` now carries an **in-`.ad`
   runtime library**: `link_runtime_externs()` scans the unresolved call
   fixups and, for every name that is a known `sys_*` runtime symbol
   (`runtime_syscall_num` — a name→syscall-number table kept in lockstep with
   `user/runtime.S`), synthesizes the SAME wrapper body
   (`emit_runtime_wrapper`: `[mov %rbp,%r9 for rfork]; mov %rcx,%r10; mov
   $N,%rax; syscall; ret`) as a real in-image function and defines its symbol,
   so `resolve_calls()` patches the call against it exactly as `ld` would. No
   external `ld` step: `elf_emit.ad` already emits all of `code[]` in its
   self-contained PT_LOAD, so the wrappers ride along with zero ELF change.
   This is the "resolve+link the known runtime symbols directly" option from
   the runbook; it is behaviorally identical to the seed's ld-against-
   runtime.S (NOT byte-identical — the seed routes through `as`/`ld`). The
   kernel boot-stub link path (`head_64.S`, `kernel.lds`) is still a separate
   capability under #3 (ELF output formats).

2. **Import resolution + module-private mangling — DONE 2026-06-21 (CAP#2).**
   The host driver (`fused_driver_host_main.ad`) now reproduces the seed's
   `collect_all_imports` + `merge_programs` front-end at the SOURCE-TEXT level:
   from the input unit's path it scans top-level `from M import ...` /
   `import M [as x]` lines, resolves each dotted module `a.b.c` to
   `a/b/c.ad` (or the package form `a/b/c/__init__.ad`) by probing the
   filesystem with `open`, transitively collects the closure in
   DEPENDENCY-FIRST order with de-duplication (mirrors `collect_all_imports`'s
   post-order), and concatenates every module's source into one merged
   translation unit with its import lines stripped (handling the
   parenthesised `from M import (` ... `)` block form). The fused parser then
   runs ONCE over the whole merged buffer. A 4th argv writes the merged source
   out so the gate can prove the merge matches the seed's closure.

   *Module-private mangling — provably a no-op on today's tree.* The seed
   mangles leading-underscore top-level names per module so two modules' `_helper`s
   coexist. A whole-tree audit (every userland import closure AND the kernel
   closure) found **zero** private-name collisions, so the straight merge is
   already collision-free and the merged program is behaviourally identical to
   the seed's. If a future private collision is introduced, `codegen.ad`'s
   existing duplicate-public-symbol path catches it deterministically rather
   than silently mis-linking. Full AST-level per-module mangling is therefore
   deferred (belt-and-suspenders, currently dead code on this tree).

   *Composes with CAP#1.* The merged multi-TU programs still resolve their
   `sys_*` externs through `link_runtime_externs`. Completing CAP#2 surfaced
   two CAP#1 gaps that were fixed alongside: (a) the `runtime_syscall_num`
   table was missing 40 SIMPLE `sys_*` wrappers (`sys_errstr`, `sys_mount`,
   `sys_getuid`, `sys_nanosleep`, …) that lib helpers like `lib/perror`
   call — added in lockstep with `user/runtime.S` (the two non-simple
   wrappers `sys_pgrp_kill`/`sys_waitpid`, which have a `negq %rdi` /
   `xorl %esi` prologue, are deliberately NOT auto-synthesized); and
   (b) `sys_rfork_thread` needs the same `movq %rbp,%r9` prologue as
   `sys_rfork`. Two codegen construct gaps that gated the merged `lib/p9.ad`
   were also fixed: `member_resolve` now types `ptr[i].field` /
   `arr[i].field` (an `ND_INDEX`-base member access), and `gen_function`
   now records a `Ptr[Struct]` parameter's pointee struct (mirroring
   `gen_method`) so `c[i].field` resolves in free functions.

   **Before→after (whole-tree gate):**
   ```
                                   CAP#1 (extern)   CAP#2 (imports)
   .ad host compiler accepted:      119 / 211        129 / 211
     single-TU:                     119              119
     multi-TU (import resolution):    0               10  (cat, whoami, initctl,
                                                          curl, wget, su, login,
                                                          u_server, u_tlstest,
                                                          test_errstr_perbackend)
   ```
   All 10 multi-TU passers are proven import-merge-equivalent to the seed's
   `collect_all_imports`+`merge_programs` closure (identical function set:
   orig-name, param count, body length) by the whole-tree gate's equivalence
   pass. The remaining 73 multi-TU rejects hit **reason-8 unsupported
   constructs** in their merged closures (the next gate after `lib/p9.ad`'s
   `c[0].buf[i] = v` — an indexed store whose base is a pointer/array struct
   FIELD, needing `gen_index_addr`/`index_elem_size` to handle an `ND_MEMBER`
   base + per-field element width) — that is CAP#4, not import resolution.
   The kernel `init/main.ad` now has its imports RESOLVED — the driver's
   closure discovery walks all **346** kernel modules.

3. **Whole-tree BUFFERS + ELF output format (CAP#3).**

   **Buffers — DONE 2026-06-22.** The kernel's 346-module closure merges to
   **~13.9 MB of stripped source / ~1.73 M tokens / 10,161 functions / 9,266
   globals / ~66 K data refs / ~42 K call fixups** — two orders of magnitude
   past the whole-COMPILER scale the fixed arrays were sized for (~315 KB,
   ~31 K tokens). Every source/output/parser/codegen fixed array was raised to
   whole-TREE scale (all are zero-init `.bss`, so `host_ac.elf`'s file size is
   unchanged — only its data-segment memsz grows, ~408 MB, well within host
   RAM): `DRV_SRC_CAP` 1 MiB→24 MiB, `DRV_FILE_CAP` 384 K→4 MiB (the per-file read
   scratch must hold the LARGEST single source file — `arch/arm64/kmain.ad`
   ~1.3 MB / `user/hamUId.ad` ~1.2 MB exceed the interim 1 MiB and were
   silently truncated); lexer
   `MAX_TOKENS` 64 K→4 M, `STRBUF` 512 K→16 MiB; parser `MAX_NODES` 64 K→4 M;
   codegen `CODE_CAP`/`DATA_BASE` 2 MiB→16 MiB, `GDATA_CAP` 64 K→4 MiB,
   `MAX_FUNCS`/`GLOBALS`/`METHODS`/`FLOAT` 1 K→16 K, `MAX_FIXUPS`/`METHOD_
   FIXUPS`/`DATA_FIXUPS` 8 K→128 K, `MAX_STRINGS` 2 K→32 K, `MAX_STRUCTS`
   256→4 K, `MAX_STRUCT_FIELDS` 4 K→64 K; `elf_emit` `ELF_BUF_CAP` 128 K→24 MiB.

   **Buffer SCOPE — host-only (critical):** the shared compiler modules
   (`lexer`/`parser`/`codegen`/`elf_emit.ad`) are imported by the ON-DEVICE
   compiler binaries too (`codegen_elf_selftest.ad`, `adder_cc_driver.ad`,
   `fused_driver_main.ad`), which boot in a **256 MiB QEMU guest** and only
   ever compile TINY programs. Whole-tree buffers baked into those files
   inflate their `.bss` to ~408 MB and **OOM the guest** (`test_selfhost_elf.sh`
   PHASE A hangs). So the on-disk literals stay at on-device scale, and the
   whole-tree scale-up lives in `scripts/concat_compiler_source.py` as
   `HOST_BUFFER_OVERRIDES`, applied **only** when fusing the HOST driver
   (`fused_driver_host_main.ad` — the single build that compiles the kernel and
   runs on the host with ample RAM). Each override is line-anchored and
   asserted exactly-once so on-disk drift fails the concat loudly. `host_ac.elf`
   gets the whole-tree buffers (memsz ~433 MB); every on-device build stays
   small (`codegen_elf_selftest.elf` `.bss` ~8.6 MB).

   The merge is no longer truncated (was stopping at 1 MiB / ~line 14990); it
   now produces the full ~10 MB stripped TU. A driver import-strip gap exposed
   by the kernel was also fixed: a **backslash line-continued** `from M import
   a, b, \` (no parens; e.g. `drivers/net/ipv6.ad`) only had its first line
   dropped, orphaning the continuation tokens — `drv_line_ends_backslash` +
   a `skipping_cont` state now strip the whole `\`-continued logical import
   line (the userland units used only the paren form, so this was the kernel's
   gap). The seed still parses the full merged TU (13,691 decls); host_ac now
   lexes+parses through to **codegen**.

   **ELF format — CAP#3b LANDED (2026-06-22): the native `.ad` compiler emits a
   kernel object that `ld -T kernel.lds` links into a bootable kernel ELF.**
   `host_ac.elf --target=x86_64-bare-metal init/main.ad <main.o>` now CODEGENS
   the whole 326 K-line kernel closure to a **relocatable ELF64 object**
   (`elf_emit_image_kernel`), and `scripts/_adder_cc.sh`'s `adder_cc_link_kernel`
   assembles header.S/head_64.S + every extra `.S` and `ld`-links them WITH that
   `.o` under `arch/x86/kernel/kernel.lds` — a byte-for-byte mirror of the seed's
   `assemble_and_link_x86_bare` (flags `-m elf_x86_64 -nostdlib -static -z
   noexecstack -z max-page-size=4096`, order `header.o head_64.o main.o
   extras…`). `ld` resolves EVERY symbol; the output is a complete higher-half
   `elf64-x86-64` ET_EXEC kernel. Pieces:

   * **`&extern` / `call extern` relocations** (codegen.ad, gated on
     `cg_target_kernel`). `gen_addr_of(ND_IDENT)` of an extern / in-unit-function
     emits `leaq sym(%rip),%rax` + an R_X86_64_PC32 EXTERN reloc; an unresolved
     call records an R_X86_64_PLT32 reloc instead of `cg_fail(7)`. A bare
     function-name used as a value (`tab[i] = _fn`) decays to `leaq sym(%rip)`.
     Intra-object data refs (`resolve_data_fixups`) become section-relative
     R_X86_64_PC32 relocs vs the `.data`/`.bss` section symbol (addend
     `off-4`) instead of baked absolute DATA_BASE disp32s, so `ld` patches them
     at the kernel.lds VMA.
   * **ET_REL emitter** (`elf_emit_image_kernel`, `eb64`/`patch64`). Writes an
     ELF64 ET_REL object: sections `.text`(code[]) / `.data`(gdata[]) /
     `.bss`(NOBITS) / `.data..percpu`(template) / `.symtab` / `.strtab` /
     `.shstrtab` / `.rela.text`. Symtab: STN_UNDEF; `.text`/`.data`/`.bss`/
     `.data..percpu` section syms; module-private (leading-`_`) functions as
     **STB_LOCAL** STT_FUNC (so same-named `_align_up`/`_read_u32_le`/… across
     modules don't collide at `ld`); public functions STB_GLOBAL STT_FUNC (so
     head_64.S's `call start_kernel` resolves); STB_GLOBAL UNDEF per referenced
     extern. `.rela.text`: one RELA per data fixup + per extern reloc.
   * **Percpu** (codegen.ad + elf_emit). `Percpu[T]` globals lay out into a real
     `.data..percpu` template (`cpu_id_pcpu` PINNED to offset 0 — the #402 ABI
     the hand-written `%gs:0` reads depend on), accessed `%gs:offset`
     (`movq %gs:off,%rax` / `movq %rax,%gs:off`), with
     `__per_cpu_template_start`/`_end` + each percpu global exported as
     STB_GLOBAL OBJECT in `.data..percpu` — satisfying setup_percpu_asm.S.
   * **Codegen construct lifts the kernel needed** (these ALSO raised the
     userland whole-tree acceptance from 134 → **194**): SysV **>6-argument
     calls** (stack args 6+ in a 16-aligned block); **indirect calls** through a
     function-pointer LOCAL or a `Fn[…]`-typed GLOBAL (`*_hook`/`*_fn`) →
     `call *%r11`; **port-I/O + atomic intrinsics** (`inb`/`outb`/`inw`/`outw`/
     `inl`/`outl`, `atomic_cas32/64`, `atomic_add32/64`) lowered inline;
     `container_of(ptr,Type,field)` + `sizeof(T)` (parsed ND_CONTAINER_OF /
     ND_SIZEOF, lowered to a field-offset subtract / compile-time fold); nested
     member access `a.b.c`; indexed struct-array/Ptr member base `a.f[i].g`;
     index over a Ptr[Struct]-returning call/cast `fn(...)[i].g`;
     multi-dimensional array **LOCALS** (`loc_type_node`); uint64-as-pointer
     scalar index base `p[i]`.
   * **Host driver import-closure cap** raised 64 → 384: `init/main.ad` has 191
     top-level imports, so `linux_abi.u_syscalls` (the 107th, defining
     `CLONE_NEWNS` et al.) was silently dropped from the merged TU.
   * **Structural match vs the seed** (both via `ld -T kernel.lds`): ELF header
     identical except `e_shoff` (AC `.text` is smaller — backends differ by
     construction); **entry `0x10004c` identical**; LOAD segment VMAs identical
     (low `0x100000`, bss `0x101000`, high-text `0xffffffff80114000`,
     AP-trampoline `0x8000`); **multiboot header bytes byte-identical** (same
     header.S); `.data..percpu` `0x48` bytes (9 globals) in both with
     `cpu_id_pcpu` pinned to its base; `__bss_start`/`__bss_end` present in both.
     Gate: `scripts/test_selfhost_kernel_elf.sh`.

   *Remaining caveat (NOT a link blocker).* `initramfs_cpio_base`/`size` are
   provided by the build-generated `initramfs_blob.S` (build_initramfs.py), not
   by codegen; the gate generates an empty blob so the standalone link
   completes. Runtime boot of the AC-linked kernel under QEMU is NOT validated
   here (host-only track); the structural + symbol-resolution match is the
   acceptance bar at this layer.

   **ELF format (USER) — SEAM landed.**
   `elf_emit.ad` emits the `x86_64-adder-user` self-contained ELF (the only
   one userland units need — behaviourally the seed's `ld`-against-runtime.S
   output via the cap#1 in-`.ad` runtime library). The output-FORMAT seam the
   seed drives by `--target` is now wired end-to-end: `elf_emit_image_target(
   entry_arg, target)` dispatches `ELF_FMT_USER` vs `ELF_FMT_KERNEL`; the
   driver parses `--target=x86_64-bare-metal` / `--kernel` (anywhere in argv,
   positionals unaffected) and `_adder_cc.sh` forwards `--target`.
   `elf_emit_image_kernel()` documents the higher-half multiboot/`kernel.lds`
   layout field-for-field and returns `ELF_ERR_KERNEL_UNSUPPORTED` with the
   PRECISE remaining prerequisites, rather than silently writing a USER-shaped
   ELF for a kernel target. Those prerequisites (cap#3b) are: **(a)** the
   boot-stub MACHINE CODE — `arch/x86/boot/header.S` (multiboot header +
   32-bit long-mode-transition stub + gdt64 + `.pgtables` + boot stack) and
   `arch/x86/kernel/head_64.S` (`start_kernel_asm_entry`→`call start_kernel`,
   `kernel_image_end`/`read_rbp`/text-bounds), which the seed routes through
   `as`/`ld` and which `codegen.ad` emits NONE of, plus the cross-references
   (head_64 `call start_kernel`; the Adder code's calls to `kernel_image_end`/
   `read_rbp`; header.S's R_X86_64_64 `movabsq $start_kernel_asm_entry`); and
   **(b)** `codegen.ad` per-SECTION streams — the user format flattens to one
   `code[]`+`gdata[]` at vaddr 0 / `CODE_CAP`, but the kernel needs distinct
   `.rodata`, `.data..percpu` (its own VMA, `%gs`-relative), the high-VMA
   (0xffffffff80…)/low-LMA `AT()` split, the AP trampoline @0x8000, and the
   `__bss_start`/`__bss_end` symbols `head_64.S`'s `rep stosq` reads. **These
   are moot until CAP#4 below: the kernel does not yet COMPILE** (it blocks in
   codegen on the pervasive `cast[Ptr[T]](e)[i]` raw-mem idiom), so neither
   `code[]` nor `gdata[]` is ever produced for it — emitting a kernel ELF now
   would be unvalidatable dead code.

4. **Unsupported constructs (reason 8 + inline asm) — now the KERNEL's
   dominant + first-hit blocker.** Userland: `init`, `shuf`, `vi`, `useradd`,
   `getty`, `umdf_host` use expression/statement forms `codegen.ad` rejects
   (root-cause each against the failing node); `insmod`/`modprobe`/`rmmod` use
   inline `asm_volatile` (surfaces as an unresolved `asm_volatile` call —
   reason 7).

   **Kernel (`init/main.ad`) — CAP#4 cast-ptr-index + member-base index
   LANDED (2026-06-22).** `gen_index_addr` / `index_elem_size` /
   `index_elem_signed` now lower an indexed load/store whose BASE is an
   `ND_CAST` to a pointer (`cast[Ptr[T]](expr)[i]`) AND an `ND_MEMBER` array/
   Ptr field (`obj.field[i]`), mirroring the seed's `gen_index_address`
   (non-Array base → `gen_expr`(base) for the pointer value / `gen_addr_of` for
   the field address, index scaled by `element_size_of` = `sizeof(T)` read off
   the cast's `Ptr[T]` target or the struct field's recorded element width).
   Both READ and WRITE paths, all element widths (uint8/16/32/64, struct), with
   sign-extension on signed sub-8-byte element loads (`emit_load_mem_rax_signed`,
   gated by `index_elem_signed`). New struct-field tables `sf_elem_size` /
   `sf_elem_signed` carry the array/ptr field element width+signedness for the
   member-base path. This idiom is **pervasive** across the kernel closure
   (~915 STORE + ~634 LOAD sites — page tables, vdso, framebuffer, mm): the
   first-hit `reason=8 kind=13` framebuffer poke `cast[Ptr[uint32]](fb_base +
   off)[0] = color` now compiles. Regression-floored by `regress_codegen.ad`
   Bug D (cast-ptr-index) + Bug E (member-base index), byte-verified through
   `codegen.ad` (`fuzz_adder_diff.sh`). Userland acceptance +2 (`passwd`,
   `shuf`); `cp`/`tar`/`useradd`/`umdf_host` advance PAST the index wall to
   their next distinct construct.

   **CAP#4b inline-asm + parse-completion LANDED (2026-06-22) — the kernel
   now PARSES end-to-end.** Three fixes cleared every lexer/parser blocker so
   `init/main.ad`'s full 233,769-line merged closure lexes + parses completely:

   * **Inline `asm_volatile("…")` lowering** (`codegen.ad gen_asm_volatile`).
     `gen_call` intercepts a call to `asm_volatile` with a single string-
     literal arg and assembles each stripped line to the EXACT bytes GNU `as`
     produces from the seed's emitted text (the seed routes asm text through
     `as`; `codegen.ad` is a self-contained byte emitter so it carries a
     bounded x86_64 assembler for the kernel's asm vocabulary). Two-pass over
     the lines: pass 1 records each `.Lxxx:` local-label block offset via
     deterministic per-instruction sizes; pass 2 emits bytes, resolving rel8
     `jmp`/`jc`/`loop` against the label table. Supported (all byte-verified):
     zero-operand `cli`/`sti`/`hlt`/`pause`/`mfence`/`int3`/`cpuid`/`pushfq`/
     `rdrand %rax`/`rdseed %rax`/`pushq`/`popq %reg`; retpoline `jmpq *%reg` /
     `call *%reg` (all 16 regs, REX.B for r8–r15); `movq $imm,%reg`; RIP-global
     `movq %reg,sym(%rip)` / `movq sym(%rip),%reg` / `movq $imm,sym(%rip)` /
     `mulq sym(%rip)` / `popq sym(%rip)` / `lidt sym(%rip)` (PC32 reloc via the
     existing `add_data_fixup`, with `sym+DISP` and the imm-to-mem disp/imm
     ordering handled). Unsupported lines fail `cg_fail(11)` rather than
     emitting wrong bytes. Triple-quoted `"""…"""` lexing was ALREADY present
     in `lexer.ad` — the prior "first blocker" diagnosis was wrong; the real
     first blocker was below.

   * **`ref`-as-keyword lexer bug.** `lexer.ad` lexed lowercase `ref` as
     `TOK_REF`, but the frozen seed's ONLY REF spelling is the capitalised
     `Ref` (`lexer.py` keyword dict). The kernel uses `ref` as an ordinary
     identifier (e.g. `_l_rcuref_get_slowpath(ref: uint64)`), so every such
     site was unparseable — surfacing as the spurious `parse error at line
     46132`. Removed the erroneous lowercase entry; `ref` now lexes as IDENT,
     matching the seed. (This — NOT triple-quotes — was the kernel's true first
     parse blocker.)

   * **`DRV_FILE_CAP` per-file read truncation.** The host driver's per-file
     read scratch was 1 MiB, but `arch/arm64/kmain.ad` (~1.3 MB) and
     `user/hamUId.ad` (~1.2 MB) exceed it; `read_file` silently truncated them,
     corrupting any closure that pulled one in. Raised to 4 MiB.

   *Correction to the earlier construct census:* a tree-wide scan of the
   kernel's merged closure (excluding comments / format-strings) finds **ZERO
   real f-string literals and ZERO real `yield` statements** — the earlier
   "15 f-strings / 4 yield" counts were false positives (`#f"`, `%f"`, the word
   "yield" in prose). So cap#4b's f-string and `yield` sub-tasks do **not**
   block the native kernel build; both constructs already have lexer/parser
   support (`TOK_FSTRING`/`ND_FSTRING_LIT`, `TOK_YIELD`) should a future
   userland unit need them.

   **CAP#4c member-over-cast-index LANDED (2026-06-22).** The construct
   `cast[Ptr[T]](e)[i].field` — an `ND_MEMBER` (`.field`) over a cast-pointer
   `ND_INDEX` — previously hit `reason=8 kind=15` at the first `PageDesc`
   access (`return cast[Ptr[PageDesc]](d)[0].flags`, merged line 3530). It now
   compiles. `member_resolve` resolves the element STRUCT off the index base:
   for a cast base via `ptr_struct_idx(cast's Ptr[T] target)`, and for an
   `Array[N, Struct]` GLOBAL base via `struct_lookup_by_node(array element
   type)` (a struct-array global takes the ND_ARRAY_TYPE layout branch so it
   never sets `glob_struct_idx`; the element struct comes off the recorded
   `glob_type_node`). The element is an in-place struct value, so
   `gen_member_address` routes through `gen_addr_of -> gen_index_addr` (the
   cap#4 cast-ptr / array path) to `&base[i]`, adds the field offset, and does
   a sized (sign-extended for signed sub-8-byte) load/store — mirroring the
   seed's `gen_member_address(IndexExpr-object) -> _resolve_struct(
   get_expr_type = PointerType/ArrayType element) -> gen_index_address`. The
   index STRIDE for an `Array[N, Struct]` global was also corrected from the
   bogus 8 that `prim_type_size(Struct)` records to `type_size_of(Struct)` (in
   both `index_elem_size` and `gen_index_addr`'s bare-ident global path),
   matching the seed's `element_size_of`. Floored by
   `scripts/test_selfhost_castptr_member.sh` (R+W, signed+unsigned field,
   cast base + array-of-struct global; behavioral identity vs the seed).

   **The kernel now advances to merged line 7843** — past every PageDesc and
   `partition_table[base+i].field` access — and stops on a NEW, distinct
   construct: **address-of an extern symbol** (`&irq_stub_240`,
   `cast[uint64](&irq_stub_240)`, `reason=8 kind=8` ND_IDENT). The `.ad`
   `gen_addr_of(ND_IDENT)` handles only frame locals and module globals; taking
   the address of an `extern def` label (defined in `irq_asm.S`, undefined in
   the TU) needs an EXTERNAL-symbol relocation in the emitted code — which is
   squarely CAP#3b (kernel-ELF byte emission with extern/function symbol
   relocs), not an address-composition lift. So the kernel's remaining codegen
   work folds into CAP#3b: `&extern_label` (extern-symbol PC32 reloc) plus the
   boot-stub bytes + per-section streams — see capability #3 above.

   Regression-floored by `scripts/test_selfhost_asm_volatile.sh` (compiles the
   full asm vocabulary through `host_ac.elf` and asserts the `as` ground-truth
   bytes; also guards triple-quote + `ref`-identifier parsing).

**Backends differ by construction**, so a byte-identical-ELF differential is
not even theoretically possible: the seed routes through GNU `as` (AT&T asm),
`codegen.ad` emits raw machine code directly. The sound equivalence metric
stays **behavioral** (the fuzz dry-run + the extern-linkage syscall-number
gate `test_selfhost_extern_link.sh`) plus **acceptance** (the whole-tree
gate) — not byte diff.

**Measured win (the reason to finish this track).** Per-compile wall-clock on
the two units both backends accept: the Python seed averages **~126 ms/compile**
(interpreter startup + interpreted codegen); `host_ac.elf` averages
**~0.4 ms/compile** — a **~300×** per-invocation speedup. With ~250 real
compilation units per image build, finishing the cutover turns the bulk of
the compile phase from tens of seconds of interpreted Python into a fraction
of a second of native execution. The win is real and large; it is gated
entirely on the four capabilities above.

**Build wiring (LANDED, default unchanged).** `scripts/_adder_cc.sh` provides
`adder_cc_compile` (a drop-in for `python3 -m compiler.adder compile`,
selected by `$ADDER_CC`: `python` default = the frozen seed/oracle; `adder` =
route through `host_ac.elf`, bootstrapped once by the seed). `build_user.sh`
and `build_installer_img.sh` now call `adder_cc_compile` for every kernel +
userland compile, so flipping the default is a one-line change once the `.ad`
compiler is capable — and `ADDER_CC=python` is the permanent escape hatch.
`scripts/test_selfhost_wholetree_diff.sh` guards the `.ad`-accepted baseline
against regression and asserts the seed still compiles 100% of the tree.

**NEXT track**: capabilities #1 (extern linkage), #2 (import resolution +
module merge), CAP#4's cast-ptr-index + member-base-index, CAP#4b inline-asm,
and CAP#4c member-over-cast-index (+ array-of-struct global member, stride fix)
have all LANDED. The `.ad` host compiler accepts **134/211** real userland
units (123 single-TU + 11 multi-TU); the cast-ptr-member construct is a KERNEL
idiom, so the userland count is unchanged by CAP#4c (the kernel itself, not in
the 211 userland units, is the consumer). The kernel `init/main.ad` now LEXES
+ PARSES fully and CODEGENS up to merged line 7843, stopping ONLY on
`&extern_label` (address-of an extern symbol — an extern-symbol reloc, folded
into CAP#3b). The remaining capability is therefore #3 — the kernel-ELF
emitter: extern/function-symbol PC32 relocs for `&extern_label`, the boot-stub
bytes, and per-section streams. Once CAP#3b lands, the native kernel compiles +
links end-to-end through the `.ad` compiler. The native-in-Adder optimizer
(IR/LICM/CSE/regalloc) is a SEPARATE downstream track that only matters AFTER
the cutover.

**Runbook — flipping the default build driver to the `.ad` binary** (NOT done
yet — BLOCKED on the four capabilities above; the seed stays as the bootstrap
and the fallback):

1. *Bootstrap order (unchanged):* the Python seed (`compiler/`,
   `codegen_x86.py`) always builds FIRST and compiles the `.ad` compiler
   source into a host binary (stage1). This is the trust root; it is never
   removed.
2. *Build stage1 once per build:* in the build entry (`scripts/build_user.sh`
   already builds `codegen_ac_driver.elf`/`adder_cc.elf` from the `.ad`
   sources via the seed — that IS stage1; reuse it), produce the host
   `host_ac.elf` the same way (`concat_compiler_source.py --with-driver` with
   the host driver + `--target=x86_64-linux`).
3. *Route `.ad`-target compiles through stage1:* add a build-config switch
   (e.g. `ADDER_CC=adder` env / a `--self-hosted` flag on the build driver)
   that, when set, invokes `host_ac.elf <in.ad> <out>` instead of `python3 -m
   compiler.adder`. Keep `ADDER_CC=python` (the current behavior) as the
   default until the switch has soaked.
4. *CI guard (must land WITH the flip):* run `test_selfhost_cutover_dryrun.sh`
   (the 100%-match differential) plus the existing on-device
   `test_selfhost_fixpoint.sh` (stage1==stage2 byte-identity) on every change
   to `compiler/*.ad`. Any behavioral mismatch or fixpoint divergence fails
   the build, so a `codegen.ad` regression can never silently reach the
   default driver. Keep `fuzz_adder_diff.sh` (1600-program differential) as
   the broad correctness net.
5. *Fallback:* the Python seed remains in-tree and selectable; a program the
   `.ad` compiler reports `unsupported` for (outside its subset) falls back to
   the seed. Flip the default only after the dry-run + fixpoint gates have run
   green across the full CI matrix for a soak window.

## Related docs

- [../x86-backend.md](../x86-backend.md) — why hand-written, codegen contract.
- [../../LANGUAGE.md](../../LANGUAGE.md) — the language reference.
- [build-test.md](build-test.md) — how the compiler is invoked by the build.
- [arch-arm64.md](arch-arm64.md) — the AArch64 backend's target.
