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
handle. **Remaining for a default-build cutover:** classes/methods, free
for-loops over arrays, structs/member access, do-while, floats.

## Related docs

- [../x86-backend.md](../x86-backend.md) — why hand-written, codegen contract.
- [../../LANGUAGE.md](../../LANGUAGE.md) — the language reference.
- [build-test.md](build-test.md) — how the compiler is invoked by the build.
- [arch-arm64.md](arch-arm64.md) — the AArch64 backend's target.
