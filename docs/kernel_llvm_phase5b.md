# Phase 5b — LINK + BOOT the LLVM-compiled Hamnix kernel

_Continues docs/kernel_llvm_scoping.md. Phases 0–5a produced a whole-kernel
`init/main.ad` closure `.ll` that passes `llvm-as-19` clean (11054/11061 funcs
emitted, 7 bailed). This phase LINKS that into a bootable higher-half kernel and
BOOTS it under QEMU. **Result: the LLVM-compiled kernel boots through the entire
kernel init to userspace, runs the hamsh shell, and executes `/etc/rc.boot` up to
the first `fork`, where it walls in the page-fault/COW handler.**_

## What was added (opt-in lane; native path untouched)

- **`scripts/build_kernel_llvm.sh`** — the Phase-5b kernel LLVM lane. Emits the
  whole-kernel `.ll` (`host_ac --backend=llvm --target=x86_64-bare-metal
  init/main.ad`), compiles it with `clang-19 -mcmodel=kernel` (matching the
  native kernel's freestanding flags), assembles the same 22 hand-written `.S`
  boot/entry stubs, and links under `arch/x86/kernel/kernel.lds` at the
  higher-half base `0xffffffff80000000` with `-nostdlib -static`. Mirrors
  `adder_cc_link_kernel` in `scripts/_adder_cc.sh`.
- **`scripts/kllvm_io_intrinsics.S`** — LLVM-lane-only definitions for the x86
  port-I/O + atomic intrinsics (`inb/inw/inl/outb/outw/outl`,
  `atomic_cas32/64`, `atomic_add32/64`). The native backend lowers these INLINE
  (`codegen.ad` `io_intrinsic_id`/`gen_io_intrinsic`, no symbol); the LLVM
  backend emits real `call`s to them, so the lane supplies matching SysV-ABI
  functions. No compiler change.

**No `adder/compiler/*` or kernel source was modified** — the native kernel
build is byte-identical by construction (the native reference kernel built from
the identical `.S`+`.lds` boots fully; see below). This is a NEW opt-in lane, not
a change to the default native build path.

## The 7 bailed functions — resolved via NATIVE-HYBRID link

All 7 are supplied by a native-compiled `main.o` through
`ld --allow-multiple-definition` (LLVM object first ⇒ first-wins for the 11054
emitted functions; the 7 symbols the LLVM object leaves undefined fall through to
the native object; native's duplicate copies of the other 11054 are dead code).

Approach chosen = **(b) native-hybrid**, not (a) fix-to-emit, because the 4
`reason=0` bails are all *very large* functions that overflow the shared
`cfg.ad` `NM_MAX = 256` distinct-names cap — `start_kernel` alone is **7674
source lines**, `do_syscall` 2275, `block_smoke_test` 2158,
`linux_u_syscall_dispatch_inner` similar. Raising `NM_MAX` resizes shared arrays
(`ssa_curdef` = `SSA_BB_MAX*NM_MAX`) used by the native/`--opt` paths and risks
the native-safety gates for no boot benefit — the mature native backend compiles
these correctly today. The other 3 (`snd_pcm_new`, `try_parse_hamnix_roots`
reason=11; `tests_core_smoke__list_walk_and_sum` reason=2, test-only) also come
from native.

| bailed fn | reason | referenced in bootable link? | source |
|-----------|--------|------------------------------|--------|
| `start_kernel` | 0 (>256 names) | YES (head_64.S entry) | native |
| `do_syscall` | 0 (>256 names) | YES (syscall_64.S + main.o) | native |
| `linux_u_syscall_dispatch_inner` | 0 | YES (dispatch) | native |
| `block_smoke_test` | 0 | not linked (unref) | native |
| `try_parse_hamnix_roots` | 11 | YES (root mount) | native |
| `snd_pcm_new` | 11 | (driver) | native |
| `list_walk_and_sum` | 2 | test-only | native |

## Link result — PASS

Whole-kernel `.ll`: `funcs=11061 emitted=11054 bailed=7`, `llvm-as-19` clean
(10 MiB bitcode). `clang-19 -O0 -mcmodel=kernel` → valid ELF64 relocatable.
Linked image `build/kllvm/hamnix_kernel_llvm.elf`: **ELF64 EXEC, statically
linked, multiboot1 magic `0x1BADB002` present, higher-half LOAD segments at
`0xffffffff80…`, entry `0x10004c`.** All symbols resolved (start_kernel/do_syscall
from native at higher-half addrs; inb/atomic_* from the io `.S`).

**`-O0` is required, not `-O2`:** at `-O2` clang INLINES the asm-passthrough
functions carrying the rdrand/rdseed retry loops, whose inline-asm bodies contain
FIXED `.L` labels (`.Lrdrand_retry`, …). Inlining duplicates those labels across
call sites → integrated-assembler "symbol already defined" (20 errors). A future
`-O2` lane needs the emitter to uniquify inline-asm labels (LLVM `${:uid}`
token). Documented in the build script header.

## Boot result — BOOTS TO USERSPACE, walls at first fork's COW fault

Booted via the BIOS GRUB-ISO path (`scripts/_kernel_iso.sh` `kernel_iso`, since
QEMU's `-kernel` rejects 64-bit ELFs), `-m 1024M` (the image's bss is ~145 MiB),
`-serial file`. The LLVM kernel executes an enormous amount of LLVM-compiled code
correctly:

- early printk, framebuffer console, `start_kernel`, `trap_init`
- full `pgtable` bringup, e820 parse, memblock (826 MiB free), COW refcount
  table, swap region, PageDesc array
- page_offset direct map **PASS**, dma-roundtrip **PASS**, cpu_entry_area
  **PASS** (IDT/GDT/TSS/DF/VERW/entry.text), KPTI staging **PASS**
- memblock/page_alloc/buddy smoke tests
- driver init, root mount, **`execve` into userspace** — loads the hamsh ELF,
  jumps to `0x0f085a2e`
- **hamsh runs**: stages 01–05, "M16.35 shell ready", sources `/etc/rc.boot`,
  "device binds applied"
- **`rfork: child created, pid=7`** — then STALLS.

Ran a full 150 s (QEMU rc=124) with **zero** further output — a genuine stall,
not `-O0` slowness (line count identical at 40 s and 150 s).

### The wall — captured fault (`-d int,cpu_reset`)

The last CPU event before the stall:

```
v=0e e=0007 i=0 cpl=3  IP=0023:000000000f06dc96  CR2=000000000f210fb7
```

= a **userspace (CPL=3) page fault, error 0x7 = present + WRITE + user** — i.e. a
**copy-on-write write fault** by the forked child (pid 7) inside its mapped hamsh
image (`0x0f000000..0x0feab000`). Only **2** `v=0e` events occur in 30 s (no
re-fault storm) and there is **no triple fault / cpu_reset**. So the LLVM-compiled
kernel page-fault / COW handler is **entered and never returns** — it hangs
handling the child's first COW write fault.

**Diagnosis.** The single hamsh task ran flawlessly; the hang appears the instant
a *second* task exists and the *first COW page copy* is required. The exercised
LLVM-compiled path — `do_page_fault` → COW copy, plus per-CPU `current`-task
access — is code the single-task boot never hit. Prime suspects, in order:

1. **`%gs` per-CPU current-task access** (Phase-3 `addrspace(256)` lowering):
   if the LLVM path resolves `current`/`current->mm` wrong, the COW handler
   walks the wrong page tables and loops. Load-bearing exactly at the
   first context-relevant fault.
2. A **reason=11-adjacent memory access** in the COW/fault path
   (`cast[Ptr[Struct]](p)[i].field` on the fault frame / vma / page desc) that
   emits subtly wrong addressing on the LLVM path.

### Best next step

Isolate the COW/fault handler: build a differential that compiles just the
`mm` fault + COW translation units both ways and compares behavior on a
synthetic COW fault, OR add a temporary serial trace at page-fault entry / in the
COW copy loop (shared source — revert after) to see whether the handler loops or
blocks. Given the fault is a textbook present+write COW at CPL=3, first verify the
`%gs` percpu `current` read returns the pid-7 task's `mm` under the LLVM lane
(clang `-S` should show `mov %gs:<off>, …`); a wrong `current` is the most likely
single cause of an entered-but-never-returns COW handler.

## Reproduce

```
scripts/build_user.sh && scripts/build_modules.sh
python3 scripts/build_initramfs.py
HAMNIX_INITRAMFS_BLOB="$PWD/fs/initramfs_blob.S" \
  scripts/build_kernel_llvm.sh build/kllvm/hamnix_kernel_llvm.elf
. scripts/_kernel_iso.sh
qemu-system-x86_64 -cdrom "$(kernel_iso build/kllvm/hamnix_kernel_llvm.elf)" \
  -smp 1 -nographic -no-reboot -m 1024M -monitor none -serial stdio
```

## Phase 5e — build-blocker + a NEW pre-fork regression fixed; back at the pid=7 wall

Re-running the lane on a FRESH host_ac (built from committed source, no stale
cache) surfaced two problems the earlier Phase-5b/5c/5d runs' stale/smaller
`.ll` had masked, then pinpointed and fixed both. The lane again reaches the
Phase-5d fork wall.

### (1) `LL_OUT_CAP` truncation — the lane no longer built at all

The emission-broadening work landed since Phase-5a (SVO_FUNCADDR, recursive
lvalue-address, array-of-struct globals — Ph4b/5a) grew the emitted whole-kernel
`.ll` PAST the 32 MiB `LL_OUT_CAP` in `adder/compiler/ssa_llvm.ad`. `ll_putc`
silently stops at the cap, so the tail of the unit was truncated MID-FUNCTION —
a cut-off `phi` (`%v3048 = phi i64 [ `) → clang `error: expected value token`.
The `.ll` was EXACTLY 33554432 bytes (== the cap), the tell-tale of a hard
truncation. **Fix: `LL_OUT_CAP` 32→64 MiB** (and the backing `llvm_out`
array). Host-only BSS buffer used ONLY on `--backend=llvm`; the native
`codegen.ad` path never touches it, so the native kernel build stays
byte-identical (kobjdiff 0). Rebuild host_ac after this change
(`_adder_cc.sh adder_cc_bootstrap`) — `build_kernel_llvm.sh` consumes the
prebuilt `build/cutover/host_ac.elf`.

### (2) `do_page_fault` LLVM-codegen miscompile — spurious SIGSEGV before the fork

With the full unit now emitting, the LLVM kernel died EARLIER than the Phase-5d
run: hamsh took a SIGSEGV at **stage-01** (`str_arena_init`'s first BSS write at
va `0xed1d60`) with `[nxdiag] NO covering VMA / tree-find=0`, even though the BSS
demand VMA `[0x479000,0x1110000)` covering that address had just been registered.

Root cause, established by a temporary-probe bisection (all reverted):
- `vma_register_bss_demand` set `task_table[6].vma_list_head = 0x0e014020`; a raw
  read-back at registration, and `task_image_lo(6)`/`img_lo(6)` reads from EVERY
  execve-tail setter, from `do_syscall` (native), and right up to and INCLUDING
  the last user `write(2)` before the fault, ALL returned the CORRECT values.
- But at `do_page_fault` entry the SAME accessors — including a `task_image_lo(6)`
  with a LITERAL index — returned **0** (`image_lo`, `vma_list_head`, even `pid`),
  so the covering-VMA lookup missed → spurious SIGSEGV. `task_table` is
  higher-half (`0xffffffff8510cbd0`, mapped in every PML4) and `cr3` is identical
  at both reads, so it is NOT a CR3/mapping issue; and the native `do_page_fault`
  reads the correct `0x400000` for the very same fault, so memory is NOT actually
  corrupted — **`do_page_fault`'s LLVM codegen mis-resolves the running task's
  `task_table[]` reads during fault handling.**
- **A/B proof:** `KLLVM_FORCE_NATIVE="do_page_fault"` → every demand fault
  resolves, hamsh runs, `/etc/rc.boot` completes (`device binds applied`), and the
  boot advances to **`rfork: child created, pid=7`** — the Phase-5d wall.

**Fix (correctness-first, native-safe): route `do_page_fault` to the
native-hybrid fallback by default** in `build_kernel_llvm.sh`
(`KLLVM_DEFAULT_FORCE_NATIVE="do_page_fault"`, still appendable via
`KLLVM_FORCE_NATIVE`). Opt-in-lane-only: no kernel source / `codegen.ad`
change, so the default native kernel is byte-identical. The exact miscompiled
construct inside `do_page_fault` is not yet isolated (the emitted prologue IR is
clean; the misread is delegated to leaf accessors that read correctly from every
other caller) — a proper `ssa_llvm.ad` fix, gated on `ssa_mem_model`, remains
open. Suspect: a large-function codegen edge or a call/return register-clobber
specific to this translation unit; `clang -S` on `@do_page_fault` vs a working
reader is the next probe.

**Net furthest point (opt-in lane, default build): `rfork: child created,
pid=7`** — identical to Phase 5d (first cross-task schedule; child READY but not
dispatched). See the Phase-5d TODO notes for that residual.

## Phase 5f — do_page_fault is NOT a task_table mis-READ; task_table is physically ZEROED (diagnosis, native-safe)

Deep static+dynamic bisection of the Phase-5e `do_page_fault` wall. **The prior
"do_page_fault's LLVM codegen mis-reads task_table[]" diagnosis is DISPROVEN.**
Root cause re-localised: the task_table accessor codegen is CORRECT; the physical
memory backing task_table is **zeroed/corrupted** between execve and the first
user page-fault when `do_page_fault` is compiled via LLVM. Kept the native-hybrid
route (default build still boots to pid=7); no compiler/kernel source change, so
the native kernel stays byte-identical.

### Method — reproduce + A/B + runtime probes (all reverted)

Built the LLVM lane with `do_page_fault` LEFT as LLVM (empty default
force-native), booted BIOS-ISO `-serial file`, and compared against the default
(do_page_fault native) build under the SAME cr3. Added temporary EMERG serial
probes (all reverted; native untouched) at: `do_page_fault` entry, the nxdiag
dump (10-slot scan), and the WRITER `set_task_image_range`.

### Evidence chain (all reliable field-access reads; & / probe-arithmetic in
large instrumented fns is itself unreliable and was discarded)

- **Same fault, same cr3, opposite result.** First user fault `va=0x0ed1d60`,
  `cr3=0x0e01d000`, current-idx=6 in BOTH builds. Native `do_page_fault` reads
  `task_table[6].image_lo=0x400000` / `vlh=0x0e014020` → demand-faults → advances
  to `rfork pid=7`. LLVM `do_page_fault` reads `task_table[6].*=0` (ALL 10 slots
  read 0) → `NO covering VMA` → SIGSEGV at hamsh stage-01.
- **Accessor codegen is CORRECT.** `objdump` of `task_image_lo`,
  `set_task_image_range`, `_another_task_ready` all materialise `task_table` via
  `mov $0xffffffff85..,%rax` with **R_X86_64_32S** (correct sign-extend for the
  higher-half symbol) + `imul $0x38d0` + displacement. Byte-identical form in the
  small accessor and the large callers. `do_page_fault` reads task_table only via
  CALLS to these accessors (no direct task_table reloc). The demand-path IR
  threads the right args: `vma_demand_fault(slot=current_idx_get(), pml4=cr3&MASK,
  fault_va)` — all three verified through the phi web.
- **Not a mapping/coverage issue.** A full 4-level walk of `task_table[6]` VA
  `0xffffffff851220b0` gives the SAME translation under the WRITER's boot cr3 and
  the READER's user cr3: `pml4e[511]=0x103023, pdpte[510]=0x800e023 (PDPT[510]
  post-`module_map`-split, 2-MiB granular), pde[40]=0x050000e3` → same 2-MiB huge
  leaf → same phys `0x051220b0`. So write and read target the SAME physical page.
- **Not a stack overflow.** live `rsp=0xffff88800e02ff38` (a healthy direct-map
  kstack address; kstack is 64 KiB). `do_page_fault`'s -O0 frame is only 0x588.
- **The physical page is genuinely ZEROED at read time.** In the LLVM build, BOTH
  the kernel-VA read (`*0xffffffff85122c70`) AND the direct-map alias read
  (`*0xffff888005122c70`) of `task_table[6].image_lo` return **0** — the phys page
  contains 0. Yet the WRITER's read-back of the very same field during execve
  returned `0x400000`. → the physical page was **written correctly then zeroed**
  between execve and the fault. The `do_page_fault` ENTRY probe (before the
  handler does anything) already sees 0, and NO earlier USER fault was observed
  (the first `dpfP` is the stage-01 BSS fault itself), so the corruption happened
  in an earlier KERNEL-mode `do_page_fault` invocation — most plausibly the
  demand fault taken by the execve arg-copy / return-to-user uaccess against
  hamsh's demand stack VMA, whose demand-zero landed on task_table's physical
  page instead of the stack page.

### Conclusion — shared vs separate

- **`do_page_fault`:** a WRITE-side corruption, not a read miscompile. The LLVM
  `do_page_fault` demand/COW page path (alloc-page + zero, or a physical
  destination computation exercised only on the fault path) writes zeros over
  task_table's own physical page during an earlier demand fault. `vma_demand_fault`
  and the accessors are shared and work when `do_page_fault` is native, so the
  defect is inside `do_page_fault`'s own compiled body (matches the Phase-5e A/B:
  forcing ONLY `do_page_fault` native fixes every demand fault).
- **`_another_task_ready` (Phase-5d pid=7 wall):** likely a SEPARATE cause, not
  the same bug — Phase 5e already routes `do_page_fault` native (so task_table is
  NOT corrupted) yet the boot still walls at pid=7 with `_another_task_ready`
  returning 0. The unifying SURFACE symptom ("a large LLVM fn sees task_table[]
  as zero on a rarely-first-hit path") is shared, but the do_page_fault mechanism
  (physical zeroing by the fault path) does not explain a pid=7 wall that persists
  with do_page_fault native. The shared-single-root-cause hypothesis is therefore
  NOT supported by the evidence.

### Fix status / next probe

Not fixed — kept `do_page_fault` on the native-hybrid route (lane still boots to
pid=7). The exact miscompiled construct is the physical-destination address
computation on `do_page_fault`'s demand/COW page path; the next probe is to trap
the EARLIER (pre-stage-01, hamsh `_start` stack) demand fault and dump the phys
page `vma_demand_fault`/COW writes to, confirming it lands on task_table's
`0x05122c70` page. A proper `ssa_llvm.ad` fix (gated `ssa_mem_model`) awaits that
pin. Native kernel byte-identical (no compiler/kernel source change this phase).

## Phase 5g — the do_page_fault codegen theory is DISPROVEN; it is a layout-sensitive latent OOB write on the pre-fault path (evidence-backed, native-safe)

Executed the Phase-5f "next probe" directly (build the lane with `do_page_fault`
LEFT as LLVM; trap the earlier fault; dump the physical write targets). The
result **overturns the 5e/5f diagnosis**: `do_page_fault`'s LLVM codegen is NOT
the cause. task_table is not zeroed by `do_page_fault`'s own demand/COW write
path (it has none). All probes reverted; native kernel byte-identical; kobjdiff
PASS (0 divergences / 11061 fns).

### What was built + measured (all instrumentation reverted)

Reproduced the corruption build (`KLLVM_DEFAULT_FORCE_NATIVE=""`, so
`do_page_fault` is LLVM), BIOS-ISO `-serial file`, `-m 1024M`, own qemu only.
Added three temporary, reverted probes:
1. **ZPROBE** in the shared `_vma_zero_phys` (the *actual* demand-zero writer):
   EMERG if `memset` target `phys < 0x06000000` (the loaded-kernel low-phys band
   where static globals like task_table live). This is the write 5f fingered.
2. **VDF** at `vma_demand_fault` entry: print `slot`, `pml4_phys`, `fault_va`.
3. **DPFENT** as the FIRST statement of `do_page_fault`: snapshot
   `printk_line_seq` and `task_image_lo(6)` BEFORE the handler body runs.

### Evidence chain — four hard facts

- **do_page_fault passes CORRECT args.** VDF at the stage-01 fault:
  `slot=6 pml4=0x0e01d000 fault_va=0x0ed1d60` — identical to the native build's
  values. The demand-call args are not miscompiled (the IR threads
  `pml4_phys = cr3 & PF_CR3_ADDR_MASK` through clean phis; confirmed statically).
- **No demand-zero ever hits low phys.** ZPROBE NEVER fired. The shared
  `_vma_zero_phys`/`memset(phys)` writes only high buddy-pool frames. **5f's
  central claim — "the demand-zero write lands on task_table's physical page" —
  is directly refuted.** `do_page_fault`'s own LLVM body contains exactly FIVE
  stores (enumerated from the emitted `.ll`): an iret_frame param-spill to its
  own alloca, three named global counters (`pf_spurious_recovered`,
  `pf_spurious_logs`, `smap_probe_faulted`), and `iret_frame[0]` on the
  smap-probe path. NONE can reach task_table. All page zeroing/copying is in the
  SHARED `vma_demand_fault`/`_vma_zero_phys`/`cow_handle_write_fault`, which are
  LLVM-compiled in BOTH the A and B builds and therefore cannot be the
  differentiator.
- **The corruption PRECEDES do_page_fault.** DPFENT, printed on the VERY FIRST
  `do_page_fault` entry, already reads `seq=0x21 (33)` and `img6=0x0` — i.e.
  `printk_line_seq` (was ~1030) and `task_table[6].image_lo` are ALREADY zeroed
  before the handler body runs. Corroborated by the serial: the `[NNNNNN]` line
  stamp collapses from `[001030]` (execve jump-to-user) to `[000033]` at the
  first fault, with only unstamped USERSPACE lines (`_start`, `stage-01`) in
  between. So the zeroing happens on the execve→first-user-fault path, not inside
  `do_page_fault`.
- **The A/B differ ONLY by a uniform 0x1000 BSS layout shift.** The two builds
  are byte-identical except for `do_page_fault`'s body (LLVM vs the appended
  native object). Symbol addresses:
  `task_table` 0x8510bbe0 (LLVM) vs 0x8510abe0 (native);
  `printk_line_seq` 0x8395c280 vs 0x8395b280 — **both shift +0x1000**. Two
  victims 27 MiB apart move by the same page, i.e. the whole BSS block shifts
  when `do_page_fault`'s body is present/absent in the LLVM object.

### Conclusion — the native-hybrid "fix" is a LAYOUT ARTIFACT, not a codegen fix

The failure is a **latent, layout-sensitive out-of-bounds write in SHARED code
executed on the execve→first-user-fault path** (LLVM-compiled in both builds, so
most likely an LLVM-codegen OOB in one of those shared functions — the defect is
LLVM-lane-specific). Toggling `do_page_fault` native/LLVM merely shifts BSS by
one page, moving `task_table`/`printk_line_seq` INTO the wild write's target
(LLVM `do_page_fault`) or OUT of it (native). That is why "force `do_page_fault`
native" appears to fix the boot — it relocates the victims, it does not correct
any miscompile. `do_page_fault` is compiled correctly. There is NO
`ssa_llvm.ad` "physical-destination address computation" bug to fix in
`do_page_fault`; the 5e/5f narrative conflated a symptom (task_table reads 0)
with a mechanism (a do_page_fault write) that the source does not contain.

### Prime suspect + precise next probe

The corrupting write uses a PHYSICAL / low-identity / direct-map alias (that is
why the ZPROBE-on-`phys` is the right instrument and a gdb watchpoint on the
higher-half VA `0xffffffff85121c80` misses it). Narrowing: `printk_line_seq`
lives in `drivers/tty/serial/early_8250.ad`, and the only LLVM-compiled shared
code that runs between `[001030]` and the fault is the **console/serial output
path** invoked for hamsh's three unstamped `write(2)` lines (`_start`,
`stage-01`) — `printk_line_seq` being a co-located victim points squarely at that
module's line-emit path. Two decisive next steps:
1. **Physical-page watchpoint** on task_table's phys frame (`~0x05121000`), NOT
   the higher-half VA — QEMU must watch by physical address (or watch the
   low-identity alias `0x05121c80`) to catch a write through the boot-cr3 low map.
2. **Force-native bisection of the console/serial + execve-return path**
   (`early_8250.ad` emit fns, the execve iret tail) via `KLLVM_FORCE_NATIVE`; the
   first addition that stops the `seq`/task_table zeroing pins the miscompiled
   function, after which `clang -S` vs native objdump isolates the OOB construct
   for an `ssa_llvm.ad` fix (gated `ssa_mem_model`).

Net: default lane unchanged — `do_page_fault` stays native-hybrid, boot still
reaches `rfork: child created, pid=7`. Native kernel byte-identical (kobjdiff
PASS, 0/11061). The separate Phase-5d `_another_task_ready` pid=7 wall is
untouched and remains a distinct issue.

## Phase 5j — the slot-6 zeroing is TIME-BRACKETED to the execve→first-user-fault gap; write-path, timer-IRQ, and _vma_zero_phys all RULED OUT (evidence-backed, native-safe)

Reproduced the Phase-5i wall with `do_page_fault` LEFT as LLVM
(`KLLVM_DEFAULT_FORCE_NATIVE=""`) and bracketed the slot-6 zeroing in TIME with
always-printing serial probes (all reverted; native kernel byte-identical, no
`codegen.ad`/`ssa_llvm.ad` change). The probes read the victims through the SAME
accessors the kernel uses (`task_image_lo(6)`, `task_vma_list_head(6)`,
`vma_tree_root[6]`), so the "correct vs 0" verdict is layout-independent.

### Reproduced wall (unchanged)
First USER fault `va=0x0ed1d60` (hamsh `str_arena_init`'s first BSS store, inside
the registered demand VMA `[0x479000,0x1110000)`) takes SIGSEGV because
`tree-find=0` / `image=[0,0]` / no covering VMA — `task_table[6].image_lo`,
`task_table[6].vma_list_head` AND `vma_tree_root[6]` all read 0, and
`printk_line_seq` collapsed ~1050→~33.

### Decisive TIME-bracket (reliable always-print probes)
- `[dbg1]` reg-insert, `[dbg2]` reg-end, `[dbg4]` **immediately before the sysret
  to userspace** (`do_execve_finish`): ALL show the victims CORRECT
  (`img=0x400000 vlh=0xe014020 vtree=0xe014020`). The whole execve leaves slot-6
  state intact.
- `[dbg5]` at `do_page_fault` ENTRY (first executable line) for the `0xed1d60`
  fault: ALL THREE read **0**. → the zeroing happens strictly BETWEEN the
  pre-sysret point and the first user fault.
- **`current_idx_get()` is a rock-steady `6` at every probe (dbg1..dbg5)** — the
  running-slot / percpu-`current` value is NOT miscompiled. Kills the
  "wrong-slot / wrong-index read" class outright.

### What runs in that gap — and every candidate RULED OUT
hamsh is a **native ELF64** ("native syscall ABI") — its `_start`/`stage-01`
lines are three `sys_write(fd≤2,…)` syscalls (`do_syscall` → `_sysarm_write` →
`vfs_write` → console cdev), NOT the Linux-ABI dispatch. Bracketing that path:
- `_sysarm_write` entry / before `vfs_write` / after `vfs_write` / after
  `_sysarm_write` (dbg6/8/9/7) — **victims CORRECT across all three writes.** The
  console write path does NOT corrupt.
- `do_syscall` entry probe — CORRECT.
- `timer_interrupt` entry + around `current_task_account_tick`, gated
  `current_idx_get()==6 && ring-3` (dbg10/11/12) — **NEVER fired**: no timer/
  scheduler tick lands on slot-6 userland in the gap. Kills the tick/preempt
  accounting hypothesis.
- **`_vma_zero_phys` ZPROBE** (EMERG if `phys<0x08000000` OR `n>0x200000`) —
  **NEVER fired** (re-confirms Phase 5g on the post-5i layout). The anon
  demand-zero page path is NOT the writer. Victim phys are all `<0x08000000`
  (`printk_line_seq`~`0x395d280`, `vma_tree_root[6]`~`0x4f14470`,
  `task_table[6]`~`0x512e760`), so a low-phys `_vma_zero_phys` WOULD have tripped
  it — it did not.
- A 5th INDEPENDENT victim: `_dbg_zchk_armed`, a FRESH `mm/vma.ad` BSS global set
  to 1 during execve, reads **0** at the fault → confirms a genuine multi-global
  MEMORY zeroing (not a read miscompile) spanning globals in ≥4 modules
  (`early_8250` `printk_line_seq`, `sched/core` `task_table`, `mm/vma`
  `vma_tree_root` + `_dbg_zchk_armed`). Final-`.bss` addresses of the victims span
  ~25 MiB and are NON-contiguous → NOT one contiguous `memset`; either several
  targeted zeroing stores or a strided/sparse clear.

### The paradox = the finding
In the gap between the last console write (dbg7, CORRECT) and the BSS fault
(dbg5, ZEROED) there is **no probed synchronous LLVM kernel function**: only
`do_execve_finish`/syscall-return ASM (hand-written, native), a few CPL-3
`str_arena_init` prologue instructions (cannot write kernel BSS), and the `#PF`
trap-entry ASM. Yet a multi-global BSS zeroing occurs. `str_arena_init`'s FIRST
store is the one that faults, so its arena-`memset` has not run — the "user zeroes
mismapped pages into kernel BSS" theory is excluded (nothing user-side wrote yet).

### Prime remaining suspects (for the next agent) + exact next probes
1. **The syscall-return / `#PF` trap-entry ASM consuming an LLVM-miscompiled
   per-CPU / KPTI / GS value** (wrong trap-stack or CR3 on the way in). Caveat:
   an errant frame push would leave register DATA (nonzero) in the victims — but
   dbg5 reads exactly `0`, which argues for a memset, not a frame overwrite.
2. **An asynchronous DMA write** to a mis-programmed descriptor (console/serial
   or block/initramfs device) completing in the gap and landing on kernel BSS.
3. **A fault at a `va` OUTSIDE `[0x400000,0x2^33)` that dbg5's gate hid**, whose
   handler does the zeroing. NEXT: re-run dbg5 with the gate replaced by a
   NON-corruptible signal (`current_idx_get()==6`, NOT the `_dbg_zchk_armed` flag
   — that flag is itself a victim, which is why an earlier `_dbg_is_armed()`-gated
   probe silently never fired), capturing EVERY hamsh fault + its `va`.

### Tooling notes (load-bearing; save the next agent the dead-ends)
- **qemu gdbstub hardware watchpoints WORK and PERSIST** (a single `watch` on
  `printk_line_seq` fires on every printk, monotonic; DR regs are NOT clobbered by
  the kernel). Multi-watchpoint (≤4) also works.
- **But two silent confounders wasted ~6 watchpoint runs:** (a) every probe
  rebuild SHIFTS `.bss` by ~0x1000, so watchpoint addresses MUST be recomputed
  from the CURRENT `nm` each build (`task_table`+`slot*0x38d0`+**offset 0xbc0**
  for `image_lo`, **0xbb8** for `vma_list_head` — the source-comment offsets 1592/
  1584 are STALE; use `objdump` of `task_image_lo`/`task_vma_list_head`); (b) a
  stale `-S -gdb` qemu holding `:1234` is trivially reconnected to — kill the qemu
  CHILD pid (not the `timeout` wrapper) and verify the connect-PC is the reset
  vector, else you are debugging a halted stale VM.
- **Watchpoint-armed boot is impractically slow** (TCG deopt: >8 min without
  reaching the first serial line when watching only late-written addresses). For
  late-boot events prefer full-speed SOURCE instrumentation (as done here) or arm
  the watchpoint late via KVM.
- `_vma_zero_phys` writes via **boot-CR3 low-identity** (`memset(phys,…)`), so its
  writes hit linear addr `== phys`, NOT the higher-half VA — watch the LOW-
  identity linear address to catch physical-destination writes.

Net: default lane unchanged (`do_page_fault` native-hybrid → `rfork pid=7`);
LLVM-`do_page_fault` lane still walls at hamsh stage-01. Native kernel
byte-identical (no compiler/kernel source change this phase; all probes reverted,
`git status` clean). Diagnosis advanced from Phase-5i's "broad slot-6 region-
zeroing (unknown when)" to a hard TIME bracket (execve-sysret → first user fault)
with the write path, timer IRQ, `_vma_zero_phys`, and the wrong-slot/percpu read
class all EXCLUDED. The separate `_another_task_ready` pid=7 wall remains
distinct.
