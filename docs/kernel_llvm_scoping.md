# Compiling the Adder kernel through the LLVM backend — scoping spike

_Scoping spike only. No compiler/kernel/codegen changes — this doc + a throwaway
sweep is the entire deliverable. Measured on the worktree branch off main
@ 30740524 (18/18 user apps build ELF64 via LLVM; kernel is the last frontier)._

## TL;DR

The kernel is **already ~93% emittable by function count** through the existing
Adder-SSA-IR → textual-LLVM-IR path. The blockers are NOT a giant pile of new
subset classes. They are **four specific, well-bounded gaps**, two of which are
worse than "bails" — they are **silent miscompiles** that the app sweep never
exposed because apps have no percpu and no inline asm:

1. **`%gs` percpu is silently miscompiled** — a percpu global read/write emits a
   plain absolute `load i64, i64* @g` instead of a `%gs`-relative access. Not a
   bail; wrong code. **Must** be modeled as address-space 256 (`addrspace(256)`),
   the standard clang gs-relative idiom. HARD BLOCKER.
2. **`asm_volatile(...)` is silently miscompiled** — it emits a bogus
   `call i64 @asm_volatile(i64 <str-ptr>)` to a nonexistent symbol instead of
   real inline asm. Not a bail; wrong code + undefined symbol at link. Needs an
   `asm sideeffect` passthrough. The good news: the asm surface is TINY
   (cli/sti/hlt/mfence + two rdrand/rdseed retry loops). HARD BLOCKER but small.
3. **One dominant real bail class (reason=11 MEMORY, ~82% of all bails)** — the
   `cast[Ptr[Struct]](p)[i].field` pattern (struct field through a computed /
   non-local pointer). Concentrated in the `mm/page.ad` `page_*` accessors that
   ride in every file's closure. A single well-defined subset extension.
4. **Whole-kernel emit overflows the 4 MiB textual-IR output buffer** — the
   native kernel is emitted as ONE translation unit (`init/main.ad` closure);
   its `.ll` is far larger than the fixed `LL_OUT_CAP = 4194304`. The buffer must
   grow or stream before a whole-kernel `.ll` can be produced.

Bare-metal linking is the **easy** part: the LLVM `main.o` is a drop-in for the
native `main.o` — same `arch/x86/kernel/kernel.lds`, same hand-written `.S`
boot/entry stubs, only the clang code model changes (`-mcmodel=kernel`, not
`small`).

**Proof-of-concept (this spike): a clean leaf kernel module compiles end-to-end
through the LLVM path to a real ELF64 object.** See §5.

---

## 1. Emit/bail sweep over representative kernel files

Method: the same `; ADDER_STAT funcs=N emitted=M bailed=K` + per-function
`; BAILED @name reason=R` mechanism the app sweep used
(`adder/compiler/ssa_llvm.ad:1225-1240`), driven by
`build/cutover/host_ac.elf --backend=llvm <file.ad> <out.ll>`. host_ac emits
each module's whole compiled closure (imports pulled in), so counts include
transitively-referenced functions, not just the named file.

**Buffer-cap caveat:** `ADDER_STAT` is emitted LAST, after all functions. Large
modules hit `LL_OUT_CAP = 4194304` (4 MiB, `ssa_llvm.ad:148`) and the trailer is
truncated → "STAT n/a". The inline `; BAILED` comments are NOT lost (they stream
as functions are processed), so bail data is still recovered from truncated `.ll`
via `grep '; BAILED'`. `defines` = count of `^define` lines actually emitted.

| file | role | .ll | funcs/emitted/bailed | defines | bailed | note |
|------|------|-----|----------------------|---------|--------|------|
| `sys/src/9/port/devhostname.ad` | leaf cdev | ok | 5 / 5 / 0 | 5 | 0 | clean — PoC target |
| `sys/src/9/port/devsnarf.ad` | leaf cdev | ok | 4 / 4 / 0 | 4 | 0 | clean |
| `arch/x86/kernel/idt.ad` | core (small) | ok | 4 / 3 / 1 | 3 | 1 | 1× MEMORY |
| `arch/x86/kernel/traps.ad` | core | ok | 109 / 109 / 0 | 109 | 0 | clean, large |
| `arch/x86/mm/pgtable.ad` | mm core | ok | 219 / 205 / 14 | 205 | 14 | 14× MEMORY (all `page_*`) |
| `arch/x86/kernel/setup_percpu.ad` | percpu core | ok | 223 / 209 / 14 | 209 | 14 | 14× MEMORY (all `page_*`) |
| `sys/src/9/port/devcpuinfo.ad` | driver (asm) | TRUNC | STAT n/a | 884 | 92 | uses `asm_volatile` |
| `sys/src/9/port/devrandom.ad` | driver (asm) | TRUNC | STAT n/a | 897 | 127 | rdrand/rdseed asm |
| `sys/src/9/port/devkeymap.ad` | driver | TRUNC | STAT n/a | 889 | 97 | |
| `arch/x86/kernel/apic.ad` | core (asm+pcpu) | TRUNC | STAT n/a | 897 | 115 | `mfence`, percpu |
| `arch/x86/kernel/syscall.ad` | core (asm+pcpu) | TRUNC | STAT n/a | 917 | 117 | `hlt`, percpu, scratch |
| `init/main.ad` | kernel root | TRUNC | STAT n/a | 426 | 31 | whole-kernel entry |

Clean-module emit ratio is high: traps 100%, pgtable 93.6%, setup_percpu 93.7%.
The bails are the SAME shared closure functions (see below), not per-file noise.

### Dominant bail classes (ranked, across all sampled `.ll`)

| reason | code | count | share | what it is |
|--------|------|-------|-------|------------|
| 11 | `SBR_MEMORY` | 500 | ~82% | `cast[Ptr[Struct]](p)[i].field` / struct field via non-local ptr |
| 2 | `SBR_NONSUBSET_EXPR` | 76 | ~12% | an expression form outside the subset |
| 4 | `SBR_NONLOCAL` | 32 | ~5% | read/write of a non-local (module-scope) variable in a promote context |

`SBR_CALL` (13) does **not** appear — inline asm does NOT bail (it miscompiles,
§2). Counts are inflated by the shared closure: the `mm/page.ad` `page_*`
accessors (`page_flags`, `page_set_flag`, `page_mapcount`, `page_rmap`, …) ride
in every module's closure, so the same ~14 MEMORY bails are counted many times.

**Representative MEMORY bail** (`mm/page.ad:124`):

```
def page_flags(pfn: uint64) -> uint32:
    d: uint64 = page_desc(pfn)
    if d == 0:
        return 0
    return cast[Ptr[PageDesc]](d)[0].flags     # <-- struct field through a
                                               #     cast/computed pointer
```

The subset only derefs a **bare local pointer identifier with a machine-width
scalar pointee** (`ssa_deref_esz`, `ssa.ad`), and `ssa_member_base_addr`
(`ssa.ad:1717+`) rejects any member base that is not a local struct/pointer.
`cast[Ptr[T]](expr)[i].field` fails both. This one pattern is the bulk of the
kernel's real bails.

---

## 2. Inline assembly

**How it works today.** `asm_volatile("...")` is a builtin-call form. The parser
also has a separate `asm("...")` → `ND_ASM` (`parser.ad:1548`), but the kernel
does not use it — the kernel uses `asm_volatile(<string literal>)`, which the
native backend lowers verbatim to machine bytes via a bounded in-tree assembler
(`codegen.ad:12417 gen_asm_volatile`, dispatched at `codegen.ad:12908`; only the
instruction set the kernel actually uses is assembled — `codegen.ad:11783+`).

**The kernel's inline-asm surface is TINY.** Only 9 `.ad` files use
`asm_volatile`, 32 sites total, and the mnemonics are trivial:

| mnemonic | sites | files |
|----------|-------|-------|
| `cli` | 11 | init/main, setup_percpu, syscall, irq, traps |
| `sti` | 7 | init/main |
| `hlt` | 7 | init/main, setup_percpu, syscall |
| `mfence` | 2 | apic |
| rdrand/rdseed retry loops | few | devrandom (`.L`-label loop bodies) |

Everything heavier — `head_64.S`, `irq_asm.S`, `sched_asm.S` (`__switch_to_asm`),
`kpti_asm.S` (cr3/swapgs), `sigret_asm.S` (iretq contexts), `cpuregs_asm.S`
(msr/cr reads), `spinlock_asm.S`, `setup_percpu_asm.S`, memcpy/memset — is
already in **hand-written `.S` translation units** (22 of them). Those are NOT
inline asm; they are separate objects the kernel links against as externs. They
**stay `.S` verbatim** under both backends — the LLVM `main.o` just `declare`s
and calls them, exactly as the native `main.o` leaves them UNDEF for `ld`.

**Current LLVM behaviour = silent miscompile.** `asm_volatile("cli")` does NOT
bail; it emits:

```llvm
%v2 = ptrtoint [4 x i8]* @.Lstr0 to i64
%v1 = call i64 @asm_volatile(i64 %v2)          ; WRONG: calls a nonexistent fn
```

i.e. a call to an undefined `@asm_volatile` with the *string* as an argument.
That links to nothing and executes no `cli`.

**Strategy — passthrough (feasible, small).** Special-case the `asm_volatile`
call in `ssa_llvm.ad` (it is already recognized by name in `codegen.ad`) to emit
an LLVM inline-asm intrinsic instead of a call:

```llvm
call void asm sideeffect "cli", "~{memory}"()
call void asm sideeffect "hlt", "~{memory}"()
call void asm sideeffect "mfence", "~{memory}"()
```

For the bounded set the kernel uses (no inputs/outputs, no clobbered GPRs beyond
memory/flags), the constraint string is trivial (`""` or `"~{memory}"`; add
`"~{cc}"` where flags matter). The rdrand/rdseed retry loops with `.L` labels are
the only multi-line bodies — the asm-string passthrough carries the body text
through unchanged (LLVM assembles it via the integrated assembler, same as the
`.S` extras). **Verdict: passthrough is feasible for 100% of the kernel's inline
asm.** No inline-asm function needs to "stay native" — but note the sites live
inside otherwise-emittable functions (e.g. `idle_loop`, syscall-entry helpers),
so until the passthrough exists those *whole functions* must fall to native.

---

## 3. `%gs` percpu

**Current LLVM behaviour = silent miscompile (HARD BLOCKER).** A `Percpu[uint64]`
global read/write emits a plain absolute access, verified with a micro-test
(`my_pcpu: Percpu[uint64]`), both with and without `--target=x86_64-bare-metal`:

```llvm
@my_pcpu = internal global [8 x i8] zeroinitializer, align 16
; read_pcpu:
%v1 = ptrtoint [8 x i8]* @my_pcpu to i64
%t1 = inttoptr i64 %v1 to i64*
%v2 = load i64, i64* %t1                        ; WRONG: absolute, not %gs-relative
```

The native backend instead lowers this to `mov %gs:cpu_id_pcpu, %rax`
(`codegen.ad`; percpu flagged at `codegen.ad:2740 glob_is_percpu[…]=1`). The
`glob_is_percpu` **exclusion in `ssa_llvm.ad` only guards the GLOBALADDR reverse
lookup** (`llvm_glob_for`, `ssa_llvm.ad:519`, used for `&global`); the scalar
load/store path does not distinguish percpu and emits the wrong absolute access.
So the directive's "the emitter already DEFERS percpu globals" is only
half-true: it defers *address-of*, not scalar read/write, which miscompiles.

**Strategy — address-space 256 (feasible, standard idiom).** On x86-64, clang
models `%gs`-relative access as `addrspace(256)` (and `%fs` as 257). A percpu
scalar access becomes:

```llvm
%p = inttoptr i64 <percpu-template-offset> to i64 addrspace(256)*
%v = load i64, i64 addrspace(256)* %p           ; clang emits `mov %gs:off, %v`
```

where `<percpu-template-offset>` is the global's `glob_offset` in the
`.data..percpu` template. clang lowers `addrspace(256)` loads/stores to a `%gs:`
segment prefix natively — no target hackery. The emitter must: (a) detect
`glob_is_percpu` on the scalar load/store path (not just GLOBALADDR), (b) emit
the offset as an `addrspace(256)` pointer, (c) leave the percpu template itself
in `.data..percpu` (the ELF-emit side already builds this section;
`elf_emit.ad:409-436`). **Verdict: feasible, and it is the standard clang
approach.** Must be paired with native-safety gating since it changes nothing on
the native path but is load-bearing for correctness on the LLVM path.

---

## 4. Bare-metal link delta

The native kernel is emitted as **one** relocatable ELF64 (`ET_REL`) object from
the whole `init/main.ad` closure:

```
host_ac.elf --target=x86_64-bare-metal init/main.ad main.o
ld -m elf_x86_64 -nostdlib -static -T arch/x86/kernel/kernel.lds \
   head_64.o … main.o … <.S extras>        (adder_cc_link_kernel, _adder_cc.sh:161)
```

`kernel.lds` places `.text/.rodata/.data..percpu/.data/.bss` at the higher-half
virtual base `KERNEL_VBASE = 0xffffffff80000000` (PML4 slot 511), with a LOW boot
region at `0x100000` (VMA==LMA) and the AP trampoline at `0x8000`
(`arch/x86/kernel/kernel.lds`).

**What changes vs `adder_cc_llvm_native64.sh` (the app ELF64 lane):**

| aspect | app lane (`init64.lds`) | kernel lane (`kernel.lds`) |
|--------|-------------------------|----------------------------|
| clang code model | `-mcmodel=small` (base 0x400000) | **`-mcmodel=kernel`** (top −2 GiB; required for `0xffffffff8…` RIP-relative) |
| output | `ET_EXEC`, `_start`, no PT_INTERP | `ET_REL` `main.o` linked into higher-half kernel ELF |
| runtime | native `runtime.S` + `print_u64` | **none** — kernel provides its own entry (`head_64.S` → `start_kernel`) |
| freestanding flags | `-ffreestanding -fno-pic -mno-red-zone -fno-stack-protector -fcf-protection=none -fno-unwind-tables` | **same** (all already correct for kernel) |
| linker script | `user/init64.lds` | `arch/x86/kernel/kernel.lds` (unchanged) |
| extra objects | native runtime | the existing 22 `.S` boot/entry/asm stubs (unchanged) |

The clang flag set the app lane already uses (`-ffreestanding -fno-pic
-mno-red-zone` etc.) is exactly what a kernel object needs. **The only real
deltas are `-mcmodel=kernel` and swapping `init64.lds`→`kernel.lds` + the `.S`
extras.** Confirmed in the PoC (§5): clang accepts `-mcmodel=kernel` on the
emitted `.ll` and produces a valid kernel-model ELF64 object. This is the
*easy* axis — the LLVM `main.o` is a structural drop-in for the native `main.o`.

**One scale blocker lives here too:** because the kernel is a single translation
unit, the whole-kernel `.ll` exceeds the 4 MiB `LL_OUT_CAP` output buffer
(§1 truncation). The buffer must be enlarged or made streaming before a
whole-kernel `.ll` can even be produced.

---

## 5. Proof-of-concept — a leaf kernel module compiles through LLVM

Target: `sys/src/9/port/devhostname.ad` (a leaf `/dev/hostname` cdev — no
percpu, no inline asm; 5/5/0 clean emit). Full path, unmodified tree:

```
# 1) Adder SSA IR -> textual LLVM IR
build/cutover/host_ac.elf --backend=llvm sys/src/9/port/devhostname.ad devhostname.ll
#    -> ; ADDER_STAT funcs=5 emitted=5 bailed=0

# 2) LLVM verifier accepts it
llvm-as-19 devhostname.ll -o devhostname.bc          # rc=0, valid bitcode

# 3) clang -c, freestanding, KERNEL code model -> real ELF64 object
clang-19 -O2 -c -ffreestanding -fno-pic -fno-unwind-tables \
   -fno-stack-protector -fcf-protection=none -mno-red-zone -fno-addrsig \
   -mcmodel=kernel devhostname.ll -o devhostname.o    # rc=0
file devhostname.o
#    -> ELF 64-bit LSB relocatable, x86-64, version 1 (SYSV)
nm -u devhostname.o                                    # (no unresolved externs)
```

**Result: PASS.** A clean leaf kernel module goes Adder → SSA IR → LLVM IR →
`llvm-as`-verified → clang → real freestanding ELF64 relocatable object, with the
higher-half kernel code model. `devsnarf.ad` reproduces the same. So the LLVM
kernel path is proven for the percpu-free / asm-free subset **today**; what
remains is closing the four gaps so the percpu/asm/`page_*`-using majority also
emits, and enlarging the output buffer for the whole-kernel unit.

---

## 6. Phased plan

Ordering principle: every phase keeps the **native backend byte-identical** (the
kernel ships native until the very end). Gate each phase on the existing
native-safety gates — `scripts/fuzz_adder_diff.sh`,
`scripts/test_native_vs_seed_kobjdiff.sh`,
`scripts/test_selfhost_kernel_elf.sh` (native kernel still links) — plus a new
per-phase LLVM-emit assertion. The LLVM path is opt-in (`ssa_mem_model != 0`);
native is untouched by construction.

**Phase 0 — output-buffer scale (unblock whole-kernel emit).**
Enlarge/stream `LL_OUT_CAP` (`ssa_llvm.ad:148`) so `init/main.ad`'s whole-kernel
closure produces a complete `.ll` with an intact `ADDER_STAT`. Prereq for
measuring real whole-kernel emitted/bailed. Low risk (LLVM-path-only constant).

**Phase 1 — the `cast[Ptr[Struct]](p)[i].field` MEMORY class (~82% of bails).**
Extend the subset (`ssa_member_base_addr` / deref path in `ssa.ad`) to accept a
member/index base that is a computed or cast pointer, not just a bare local. This
single class clears the `mm/page.ad` `page_*` accessors that dominate every
module's closure. Gate: native byte-identical + those functions now `define` in
the `.ll`. Biggest emit-coverage win per unit effort.

**Phase 2 — inline-asm passthrough (correctness; HARD BLOCKER, small).**
Special-case the `asm_volatile` call in `ssa_llvm.ad` to emit
`call void asm sideeffect "<body>", "<constraints>"()` instead of the bogus
`@asm_volatile` call. Covers 100% of the kernel's 32 sites (cli/sti/hlt/mfence +
rdrand/rdseed loops). Gate: emitted asm matches the native bytes' effect;
functions containing asm now emit instead of miscompiling.

**Phase 3 — `%gs` percpu via addrspace(256) (correctness; HARD BLOCKER).**
Detect `glob_is_percpu` on the scalar load/store path and emit
`addrspace(256)` pointers at the percpu-template offset; keep the template in
`.data..percpu`. Gate: `%gs:`-prefixed access in clang `-S` output; native path
unchanged. Load-bearing for any SMP/per-CPU correctness.

**Phase 4 — residual bails (reason 2 NONSUBSET_EXPR, reason 4 NONLOCAL).**
Sweep the now-much-shorter tail after Phases 1-3 (measure on the whole-kernel
`.ll` from Phase 0). These are ~17% of today's bails and likely a handful of
distinct expression/nonlocal patterns. Close per-pattern, native-gated, until
`init/main.ad` emits 100% (or the residual is a deliberate, documented
native-only set that `ld` still resolves from `.S`).

### Phase 4 results (whole-kernel `init/main.ad` closure, 11061 funcs)

The reason=11 MEMORY bail was NOT one shape but four; after Phases 0-3 the
`cast[Ptr[Struct]](p)[i].field` LOCAL form was already handled, but the two
biggest remaining sub-shapes were **module-scope (global) struct access**, which
the app sweep never exercised:

| reason=11 sub-shape (before) | count | site | status |
|------------------------------|-------|------|--------|
| `g[i].field` — global `Array[N, Struct]` indexed then field | 652 | member-base ND_INDEX, non-local base | **CLOSED** |
| `g.field` — in-place `Struct` global | 305 | member-base ND_IDENT, non-local | **CLOSED** |
| `&x` — x neither mem-local nor non-percpu global (percpu/other) | 107 | addr-of ND_IDENT | tail |
| `&expr[i]` — index base not a bare ident (member/computed/2-D) | 63 | addr-of ND_INDEX | tail |
| `base[i].field` — index base not ident/cast (member/call) | 56 | member-base ND_INDEX | tail |
| `&obj.field` / `&*p` — addr-of member/deref | 16 | addr-of fall-through | tail |
| `obj.field` — obj not ident/index (`a.b.field`, `(*p).field`) | 8 | member-base fall-through | tail |
| misc singletons | ~4 | | tail |

Closing the two global buckets is a bounded subset extension in
`ssa.ad` (two new helpers, `ssa_global_struct_base` +
`ssa_global_indexed_struct_base`, wired into `ssa_member_base_addr`), gated on
`ssa_mem_model != 0` so the native `codegen.ad` path is byte-identical. Both use
the existing global machinery (`glob_lookup`, `ssa_globaladdr`,
`glob_struct_idx`, `glob_type_node`, `st_total`); the in-place struct global's
symbol address IS the struct base, and the array-of-struct element is
`symbol_addr + idx*st_total(Struct)`. The `Ptr[Struct]`-GLOBAL forms are
deliberately left BAILING (no kernel site uses one — 0 measured — so no untested
memory-emit path ships; a bail is safe).

**Whole-kernel emit: 9759 → 10575 emitted (+816), 1302 → 486 bailed (−63%).**
Per-reason after: **365 reason=11, 68 reason=4, 49 reason=2, 4 reason=0** (the
non-11 counts rise slightly — 40→68, 46→49 — because functions that used to bail
on the global-struct shape now emit further and surface a deeper blocker). Fully
verified native-safe: fuzz 500/500 correct (native + `ADDER_OPT2`), kobjdiff 0
divergences across 11061 funcs, bench_llvm 8/8 AGREE, and a native-vs-LLVM
differential on `g.field` / `g[i].field` / sub-8-byte-field forms (identical
output, clang `-O2` accepts the IR).

**Documented remaining Phase-4 / Phase-5 tail (486 bails):**

- **reason=11 (365)** — all "address of / member through a NON-bare-ident base":
  `&x` for a percpu/non-addressable ident (112), `&expr[i]` where the index base
  is a member/computed/2-D expr (95), `base[i].field` / `obj.field` where the
  member base is itself a member/call/deref (94+10), `&g[i]` on an unrecognised
  base (47), plus a few singletons. These all need the same broader IR feature:
  **recursive lvalue-address lowering** (compute the byte address of an arbitrary
  nested member/index/deref lvalue), not another bounded special-case. Left
  bailing (safe) pending that feature.
- **reason=4 NONLOCAL (68)** — reading a **non-scalar module-scope global**
  (whole array/struct value, or a percpu scalar) in a promote context where only
  a machine-width scalar global is modeled.
- **reason=2 NONSUBSET_EXPR (49)** — **indirect / function-pointer calls** (`p()`
  through a local fn-pointer, 48) plus one singleton. Needs indirect-call
  lowering.
- **reason=0 (4)** — functions whose SSA build returns no entry (pre-existing;
  unrelated to the memory subset).

Note for Phase 5: the whole-kernel `.ll` currently fails `llvm-as` on a
`declare`/`define` name collision (e.g. `@kmod_linux_load_hook` is both
declared as an extern and defined) — a link-unit concern orthogonal to the
subset, to resolve when wiring the kernel link lane.

**Phase 5 — kernel link lane + boot.**
Add a `adder_cc_llvm_native64`-analog kernel lane: `-mcmodel=kernel`, link the
whole-kernel LLVM `main.o` with `kernel.lds` + the 22 existing `.S` extras
(mirror `adder_cc_link_kernel`). Boot under OVMF/KVM and run the visual/render
gates. Cut over only when: native gates green + the LLVM kernel boots and renders
+ a measured speedup justifies it. Keep native as the default + oracle
(same posture as the app cutover and the SSA-optimizer rewrite).

### Honest magnitude

This is **1 scale fix + 1 real subset class + 2 correctness passthroughs + a
short residual tail + a link lane** — NOT a from-scratch backend. The kernel is
already ~93% emittable by function count; the two "blockers" (percpu, asm) are
small in surface but must be *correctness* fixes (they miscompile today, they do
not bail, so they will not announce themselves — they need explicit tests). The
`page_*` MEMORY class is the one genuinely broad subset extension. Sequence the
correctness fixes (Phases 2-3) with dedicated behavioural tests, not just
emit-count gates, because the failure mode is silent wrong code, not a loud bail.
```
