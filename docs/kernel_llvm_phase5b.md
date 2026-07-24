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

## Phase 5k — the stage-01 wall is a DEBUG-PROBE LAYOUT ARTIFACT; a CLEAN do_page_fault-LLVM kernel boots past it (TCG+KVM); the writer is a deterministic CPU store, NOT DMA (evidence-backed, native-safe)

Phase 5k reproduced from a **clean, probe-free** emit and overturns the framing of
5b–5j: the "stage-01 multi-global BSS zeroing wall" they all chased is **induced
by the debugging instrumentation itself**. All probes reverted; no
`codegen.ad`/compiler/kernel-source change (the one temporary probe in
`trap_diag.ad` was reverted); native kernel byte-identical by construction.

### Method (fast, reproducible — clang -O0 of the 33 MiB `.ll` is ~4 s, not minutes)
Emitted the whole-kernel `.ll` from CLEAN worktree source with
`KLLVM_DEFAULT_FORCE_NATIVE=""` (do_page_fault LEFT as LLVM), clang-19 -O0
-mcmodel=kernel, linked with the existing boot `.S`/initramfs/native-hybrid
objects, BIOS-GRUB-ISO boot under BOTH `-accel tcg` and `-accel kvm -cpu host`.
For the corruption A/B, re-added a **minimal single-BSS-global probe** at
`do_page_fault` entry (`scripts/kllvm_repro_bss_zero.sh` drives the shape).

### Hard results
1. **A CLEAN do_page_fault-LLVM kernel boots PAST stage-01 to `rfork: child
   created, pid=7`** — identical to the native-hybrid default — under **both TCG
   and KVM**. The stage-01 SIGSEGV does **not** occur without instrumentation.
   Emit stat: clean `funcs=11064 emitted=11059`; the failing probe9 build was
   `funcs=11065` (one extra probe fn/global). **Adding even ONE `.bss` probe
   global shifts `.bss` so the wild store lands on task_table[6]/printk_line_seq/
   vma_tree_root → the stage-01 wall.** This is the Phase-5g layout artifact,
   now demonstrated cleanly: every 5b–5j "wall" observation carried probes.
2. **The corruption reproduces under KVM**, not TCG-only: with the +1-global
   probe, after `pid=7` the first `do_page_fault` reads `task_table[6].image_lo=
   image_hi=0` AND the probe's own fresh `.bss` global `=0`; `printk_line_seq`
   collapsed ~550→0 then re-incremented. So it is NOT a TCG emulation quirk — it
   happens under hardware virtualization (i.e. would happen on real HW too).
3. **GENUINE physical-memory zeroing**, confirmed CR3-independently via the QEMU
   monitor `xp` (physical) read: `xp/1gx <phys(img6)>` = `0x0`,
   `xp/1gx <phys(printk_line_seq)>` = `0xa` (the post-collapse re-increment) —
   NOT a per-CR3 mapping/read artifact. Consistent with KPTI gated OFF
   (`cpu_mitigations.ad` `kpti_live=0` → #PF does not switch CR3; do_page_fault
   runs under the faulting task's own CR3, which maps the kernel).
4. **DMA vs CPU = CPU store.** `-nic none` (removing the default e1000 whose
   SLIRP RX polling is the only active-DMA source) does **NOT** stop the
   corruption; the default `pc` machine has no other post-boot DMA (CD/IDE idle,
   no AHCI/xHCI/virtio devices present). → the writer is the **deterministic
   layout-sensitive wild OOB store in SHARED LLVM code** (Phase 5g), NOT async
   device DMA.
5. **Not a constant-offset OOB.** `scripts/scan_oob.py` (5i's "global declared
   too small" catcher, added to `scripts/` this phase) = **0** on the current
   `.ll` — 5i's `llvm_glob_bytes` fix holds. The residual is a **variable-index
   / stride** (or pointer-arith) miscompile that constant-offset scanning cannot
   see, e.g. an array-of-struct `g[i].field` / nested `g[i].arr[j]` store whose
   INDEX STRIDE is wrong. The corruption fires on the execve→stage-04 path and
   again at rfork/pid=7 — both dense with variable-index `task_table[idx].field`
   writes and zeroing loops (e.g. `seccomp_native_filter[j]=0`, `fpu_area[]`).

### Tooling reality (load-bearing — do NOT repeat these dead-ends)
- **Hardware watchpoints are USELESS for this bug.** TCG deopts too slow to reach
  the late event (stalls in early boot at printk_line_seq≈40 after minutes —
  matches wp7). The **KVM gdbstub DR watchpoints are clobbered by the kernel's
  own DRn writes** early in boot: an armed watch catches only the very-early
  `.bss` clear (pc `0xffffffff80114018`) and then MISSES even the legitimate
  execve store of `task_table[6].image_lo=0x400000`. This is why 8 prior agents
  could not catch the store.
- **The productive instruments:** (a) a MINIMAL +1-global source probe at
  do_page_fault entry; (b) the QEMU monitor `xp <phys>` CR3-independent physical
  read (`-monitor unix:...,server,nowait`, `stop`, `xp/1gx`); (c) the
  clean-vs-probe layout A/B and `-nic none` device-quiesce. `phys = VA -
  0xffffffff80000000` for higher-half globals; `task_table[slot].image_lo =
  task_table + slot*0x38d0 + 0xbc0` (verify stride/off by `objdump -d
  <task_image_lo>` each build — they drift).

### Next steps (for the next agent)
- **STOP adding probes to chase stage-01** — probes move the target. Boot clean.
- **Hunt the variable-stride store statically:** extend `scan_oob.py` to model
  `getelementptr` / `mul index,stride`+`add base` chains and flag `stride !=
  element_size` for array-of-struct and nested-array globals; focus on the
  stores `ssa_llvm.ad` emits via `ssa_global_indexed_struct_base` / the recursive
  lvalue-address walker for `task_table[idx].*` and nested `[i].arr[j]`.
- **OR clean-build differential:** dump `.bss` physically (`xp`) at pid=7 in the
  clean do_page_fault-LLVM build and diff vs the native kernel's expected values
  to locate the wrongly-zeroed hole → back-map to its source global → identify
  the writing loop, then `clang -S` vs native objdump on that store.
- **`KLLVM_DEFAULT_FORCE_NATIVE=do_page_fault` may be unnecessary:** a clean
  do_page_fault-LLVM build boots to pid=7. Re-test a full clean
  `build_kernel_llvm.sh` with `KLLVM_DEFAULT_FORCE_NATIVE=""` before flipping the
  default (the wild store is in shared code and layout-dependent, so a full build
  could still land it on a victim — verify, don't assume).

Net: default lane unchanged (`do_page_fault` native-hybrid → `rfork pid=7`).
Diagnosis corrected: the stage-01 wall = debug-probe layout artifact; the true
defect = a deterministic CPU wild-store (variable-index/stride miscompile) in
shared LLVM code, genuine physical zeroing, NOT DMA and NOT do_page_fault-specific.
Native kernel byte-identical (no compiler/kernel source change; probe reverted;
`git status` clean bar the new `scripts/scan_oob.py`, `scripts/kllvm_repro_bss_zero.sh`,
and this doc). The separate `_another_task_ready` pid=7 wall remains distinct.

## Phase 5l — the WRONG-STRIDE store hypothesis is REFUTED: the emitter's array-of-struct / nested strides are CORRECT (static scan + emit differential, native-safe)

Executed the Phase-5k "hunt the variable-stride store statically" plan:
extended `scripts/scan_oob.py` to model VARIABLE-index addressing and ran it on
a clean whole-kernel `.ll`, plus a positive/negative emit differential. **Result:
there is NO wrong-element-stride array-of-struct store in the kernel; the Adder
LLVM emitter computes `g[i].field` / `g[i].arr[j]` element strides correctly.**
Only `scripts/scan_oob.py` changed — a host analysis tool, NOT compiler/kernel
source — so the native kernel is byte-identical by construction and no
native-safety gate is at risk (no `codegen.ad`/`ssa*.ad`/kernel `.ad` change).

### Scanner extension (committed)
`scan_oob.py` now tracks, per SSA value, an address model `@sym[+const]
[+ i*STRIDE ...]` by parsing `ptrtoint [N x i8]* @sym`, `mul i64 %i, STRIDE`,
`shl`, `add`, `inttoptr`, and `store/load` chains (the exact pure-pointer
arithmetic the emitter produces). Beyond the Phase-5i constant-offset OOB it
flags:
- **TILE** — the LARGEST (outer array-of-struct element) stride does not divide
  the global size N. A correct element stride must tile the array exactly; a
  stride set to the innermost element width instead of `st_total` fails this.
  Only the max stride is checked — inner strides are bounded within the element
  and legitimately do not divide N (checking them false-positived on every
  nested `g[i].inner[j]`).
- **FIELDOVF** — a constant field offset + access width that spills past the
  element the outer stride tiles (a too-small element stride).
- **INCONSIST** (informational) — a global indexed with >1 distinct stride
  (expected and benign for nested array-of-struct; NOT a defect by itself).
- A `mul CONST, CONST` (a constant-folded `[0]` index, e.g. `mul i64 0, 8` from
  `cast[Ptr[uint64]](&g[0])[0]`) is folded into `off`, NOT recorded as a stride —
  without this every constant-index cast-pointer store false-positived.

### Validation (positive + negative control)
- On a synthetic `Array[7, Elem]` with `Elem{ id; arr: Array[5,Inner]; tag }`
  (`st_total(Inner)=24`, `st_total(Elem)=136`), the emitter produced
  `@gtab = [952 x i8]` (7×136) and addressed `gtab[i].id` = `base + i*136`,
  `gtab[i].tag` = `base + i*136 + 128`, `gtab[i].arr[j].a` =
  `base + i*136 + 8 + j*24`, `gtab[i].arr[j].c` = `+ j*24 + 16` — **every stride
  equals the true `st_total`.** Scanner: 0 TILE / 0 FIELDOVF (positive proof the
  emitter is correct AND that the scanner is clean on correct nested code).
- Injecting the exact suspected bug (outer stride 136→24, i.e. the inner element
  size) makes the scanner fire TILE (`952 % 24 = 16`) on both `gtab[i]` stores —
  the scanner detects the bug class it was built for.

### Whole-kernel scan result — CLEAN
`funcs=11064 emitted=11059`; **constant-offset OOB = 0, genuine wrong-stride = 0.**
`task_table` (`[7446528 x i8]`) is indexed with outer stride **14544**, and
7446528 / 14544 = **512 exactly** — the correct element stride and count. The
seccomp / fpu / per-slot suspects likewise tile cleanly. The scanner's raw TILE
list reduced to two hits, BOTH reviewed and refuted as false positives inherent
to not distinguishing a single-struct-with-inner-array from an array-of-struct
purely from the `.ll`:
- `@blk_plug_g` (`blk_plug_g: BlkPlug`, a SINGLE struct) — stride 32 is its
  `reqs: Array[32, BlkReq]` inner-array stride; bounded within the 1040-byte
  struct (`16 + 31*32 + 32 = 1040`), not OOB.
- `@https_gzip_body` (`Array[4096, uint8]`, a FLAT byte buffer) — stride 28 is a
  manual 28-byte record layout; all offsets < 4096.

### Conclusion + redirect for the next agent
The Phase-5k "variable-index/stride miscompile" framing is **disproven for the
element-stride case**: `ssa_global_indexed_struct_base`, the recursive lvalue
walker (`ssa_region_base`/`ssa_struct_base_rec`/`ssa_addr_index`), and the
array-size reservation (`llvm_glob_bytes` → `type_size_of` = `count*st_total`)
all agree on `st_total`, so `g[i]` never overruns via a wrong stride. The wild
store that physically zeroes `task_table` is therefore NOT a statically-visible
global-rooted variable-index overrun. The two remaining classes static analysis
canNOT see, and which the next agent should pursue:
1. **Right stride, index EXCEEDS element count** — a runaway/mis-bounded loop or
   slot index (`table[j]` with `j` past the count). Not visible without loop-bound
   analysis; hunt by capping/asserting the index at each `task_table[...]` /
   per-slot zeroing writer, or a physical-`.bss` diff at pid=7 vs native.
2. **A store through a pointer NOT rooted at `ptrtoint @global`** — notably the
   PHYSICAL / direct-map alias writes Phase 5j/5k already fingered (`phys =
   va - 0xffffffff80000000` / `va & MASK`), which write to linear addr == phys and
   are invisible to a global-rooted scanner. This matches the 5j/5k finding that
   the write hits the LOW-identity address, not the higher-half VA. This is now
   the prime suspect: back-map the zeroed `.bss` hole to the SHARED function whose
   physical-destination pointer arithmetic is wrong, then `clang -S` vs native.

Net: default lane unchanged (`do_page_fault` native-hybrid → `rfork pid=7`).
Native kernel byte-identical (only `scripts/scan_oob.py` + this doc changed; no
compiler/kernel source touched). The separate `_another_task_ready` pid=7
scheduler wall remains the actual boot blocker once the wild store is found.

## Phase 5m — ROOT PINNED: `memblock_alloc` LLVM codegen returns a `.bss`-colliding base; the wild store is a BULK memset over `.bss` (not per-slot/stride); it is the SAME bug behind BOTH walls (evidence-backed, native-safe)

Phase 5m reproduced the lane from a CLEAN, probe-free emit and **overturns both the
Phase-5k framing ("clean boots to pid=7") and the 5k/5l "variable-index/stride"
hypothesis**, then pins the miscompiled function by single-variable force-native
bisection and confirms the brief's unification hypothesis. No `codegen.ad` /
`ssa*.ad` / kernel `.ad` change (only `scripts/build_kernel_llvm.sh`'s
force-native DEFAULT + this doc); native kernel byte-identical by construction.

### 1. A CLEAN full-LLVM lane walls at stage-01, NOT pid=7 (overturns 5k)
Built `build_kernel_llvm.sh` with `KLLVM_DEFAULT_FORCE_NATIVE=""` (do_page_fault
LEFT as LLVM, ZERO probes) and booted under `-accel kvm -cpu host`. It
DETERMINISTICALLY walls at hamsh **stage-01** — `[pf] user fault on unmapped
va=0x0ed1da0 -> SIGSEGV`, `NO covering VMA`, `printk_line_seq` collapsed
~1080→33 — reproduced identically across runs. Phase 5k's claim that a clean
do_page_fault-LLVM kernel boots PAST stage-01 to pid=7 is **not reproducible on
current main**; the wild store is LIVE in the clean lane and the `do_page_fault`
native-hybrid default merely shifts BSS layout off the (then-visible) victims.

### 2. The wild store is a BULK contiguous memset over `.bss` starting at `__bss_start` (refutes 5k/5l per-slot/stride framing)
At the stall, QEMU-monitor `xp` PHYSICAL reads (CR3-independent, layout-invariant
— NOT a `.bss`-shifting source probe) show a single LARGE **contiguous** zeroed
region. Fine boundary scan: the stable-zero begins at phys **0x391d000**, which
`nm` resolves to **`__bss_start` / `fb_base`** exactly. Every fb-console global
(`fb_base`,`fb_pitch`,`fb_width`,`fb_height`,`fb_shadow_base`) reads 0;
`printk_line_seq`, `vma_tree_root[*]`, `task_table[*]` (all above `__bss_start`)
read 0. So the writer zeroes `[__bss_start, ...)` — a **bulk memset**, not the
scattered array-of-struct/variable-stride store 5k/5l chased (scan_oob correctly
found 0 of those). `-nic none` does not stop it (5k: CPU store, not DMA).

### 3. Single-variable bisection PINS `memblock_alloc`
Using the layout-invariant force-native mechanism (`kllvm_force_native.py`
declare-ifies a function so the native-hybrid copy is linked):
- **`memblock_alloc` native, everything else LLVM (do_page_fault INCLUDED as
  LLVM)** → stage-01 wall GONE; boot advances PAST `rfork pid=7`, through
  rc.boot, into the `kmod_linux` module-load stage (stops later at an UNRELATED
  `#GP` on Linux static-call relocation `__SCT__might_resched`, rip
  `0xffffffff8c61a956`). ~3900 serial lines vs ~1090 at the wall.
- **`region_alloc` native, `memblock_alloc` LLVM** → still walls at stage-01
  (identical `va=0x0ed1da0`). So region_alloc is NOT the writer.
- Forcing the whole exec-alloc group native reaches the SAME far downstream
  `#GP` as `memblock_alloc` alone — memblock_alloc accounts for the entire fix.

The 24 MiB-wide `.bss` hole is anchored at the fixed `__bss_start` symbol with
`task_table` ~24 MiB inside it; memblock_alloc's sub-page instruction removal
cannot shift a hole that wide off `task_table`, so reaching kmod-load is a REAL
disappearance of the corruption, not a victim relocation.

### 4. Mechanism + UNIFICATION (both walls are the same bug)
The LLVM-compiled `memblock_alloc` returns a kernel-image / `__bss_start`-
colliding base (which is why the hole starts EXACTLY at `__bss_start`).
`region_alloc(file_hi_rel)` cold-miss carves that base and hands it to
`_load_elf64`, whose eager `memset(region,0,file_hi_rel)` + PT_LOAD `memcpy`
zero/overwrite `.bss` from `__bss_start` — clobbering `task_table`,
`printk_line_seq`, `vma_tree_root`, the fb console state, etc. That single
corruption produces BOTH walls: the stage-01 SIGSEGV (task_table[6] VMA state
zeroed → `NO covering VMA`) AND the Phase-5d/5k **pid=7 wall**
(`task_table[child].state`/`rq_cpu` clobbered → `_another_task_ready()==0` →
child never dispatched). The brief's unification hypothesis is CONFIRMED: fixing
`memblock_alloc` clears the pid=7 wall too.

### 5. do_page_fault-native was a layout artifact (confirms 5k's own caveat)
The winning bisection build keeps `do_page_fault` as LLVM and boots past both
walls — so `do_page_fault`-native was never needed; it only relocated the
victims. The default is therefore switched **`do_page_fault` → `memblock_alloc`**.

### Fix status + the open ssa_llvm.ad defect
Landed the correctness-first, native-safe route: `KLLVM_DEFAULT_FORCE_NATIVE`
default is now `memblock_alloc` (opt-in-lane-only; no compiler/kernel source
change, native byte-identical). The exact codegen defect INSIDE
`memblock_alloc` is NOT yet isolated to an instruction: its arrays are correctly
sized (`memblock_region_start`/`_end` = `Array[16,uint64]` → `[128 x i8]`,
capped at `MEMBLOCK_MAX_REGIONS=16`, indexed `base+i*8` — all correct), and the
`-O0` `clang -S` asm of the loop/return looks semantically equivalent to the
native objdump. Prime remaining suspects for the `ssa_llvm.ad` fix (gate
`ssa_mem_model`): (a) the loop **phi-web return threading** (the found-flag +
result carried out of the region-scan loop via nested phis — the exact SSA
construct the Braun builder emits for a mid-loop early result), or (b) a
**hybrid-link `--allow-multiple-definition` global-resolution** interaction on
`@memblock_region_start`/`@memblock_nr_regions` (both the LLVM object and the
native `main.o` define every global; a first-wins vs. init-writer mismatch could
make LLVM `memblock_alloc` read an UNINITIALIZED copy → base 0/low). NEXT: dump
the FULL `clang -S @memblock_alloc` vs native side-by-side focused on the return
value and the `@memblock_region_start` relocation target, and/or a host
differential of the region-scan loop shape.

Net: opt-in lane now boots PAST stage-01 AND pid=7 to the kmod-load stage
(new furthest point; residual = an unrelated Linux static-call `#GP`). Native
kernel byte-identical (only `scripts/build_kernel_llvm.sh` default + this doc;
no compiler/kernel source touched). Reproduce: `KLLVM_DEFAULT_FORCE_NATIVE=""
scripts/build_kernel_llvm.sh <out>` walls at stage-01; the default (memblock_alloc
native) boots past pid=7.

## Phase 5n — Phase-5m's "past pid=7 / kmod-load furthest point" is OVERTURNED; the walls UNIFY as ONE persistent bulk-`.bss` wild store that memblock_alloc-native did NOT eliminate — it only shifted the victim (evidence-backed, native-safe)

Reproduced the DEFAULT lane (`memblock_alloc` native, KVM `-cpu host`) from clean
source and ran the un-confounding A/B the brief asked for. Result confirms the
orchestrator's HONEST repro (commit 7a1bf7bf) and **overturns Phase 5m's central
claims**: the default lane does NOT reach pid=7, the kmod-load `#GP` is NOT "past
pid=7", and `memblock_alloc`-native is a layout artifact — the Phase-5g/5k/5m
bulk-`.bss` wild store is STILL LIVE. No source touched; `git status` clean bar
this doc; native kernel byte-identical by construction (no `codegen.ad`/`ssa*.ad`/
kernel `.ad`/`build_kernel_llvm.sh` change this phase).

### 1. Ground truth A/B (same harness: BIOS-GRUB-ISO, `-accel kvm -cpu host`, `-m 1024M`)
- **NATIVE kernel** (`adder_cc_link_kernel init/main.ad`, same `.S`/initramfs):
  boots FULLY — hamsh `M16.35 shell ready`, stage-05, `rfork: child created,
  pid=7` **dispatched**, then pid=8…**pid=26**, stage-06/07/08, interactive
  `hamsh$` prompt, `pid N exited`. `kmod_linux` (usbcore/…) init_module returns
  cleanly (`relocations applied=14183 skipped=0`, **unresolved=0**).
- **DEFAULT LLVM kernel** (`memblock_alloc` native): does **NOT** reach userspace
  at all. It walls at **`[boot:35]` kmod_linux init_module** with a `#GP`
  (`TRAP vector 0x0d rip=0xffffffff8c61a956`), preceded by **3290 SKIPPED
  relocations** and thousands of `unresolved external symbol` (`__x86_return_thunk`
  601, `__fentry__` 510, `mutex_unlock`, `kfree`, … essentially the WHOLE
  Linux-ABI export table). Userspace/hamsh launches at boot:37+, so this `#GP` is
  **BEFORE** pid=7 — Phase 5m's "boot advances PAST rfork pid=7 into the
  kmod-load stage" is FALSE (boot ordering: module load is IN `start_kernel`,
  hamsh is later).

### 2. Root symptom PINNED by CR3-independent physical read (QEMU-monitor `xp`)
At the `#GP`, `xp` of the export table's PHYSICAL frames:
`NR_EXPORTS` (phys `0x05109c40`) = **0**; `export_names[0..3]` (`0x05109c50`) =
**0**; `export_addrs[0..3]` (`0x05111c50`) = **0**. The table is PHYSICALLY
EMPTY. So `linux_abi_lookup` correctly returns 0 for every symbol → every UND
relocation is skipped → usbcore's `init_module` calls an unrelocated
`__SCT__might_resched`/`fortify_panic` site → `#GP`.

### 3. `linux_abi_lookup`'s LLVM codegen is CORRECT (disassembly-verified) — NOT the bug
`objdump` of `@linux_abi_lookup` in the real ELF: `NR_EXPORTS` read RIP-relative
at the right address (`mov 0x…(%rip) # <NR_EXPORTS>`), `export_names[i]`/
`export_addrs[i]` addressed as `base + i*8` with the correct immediate bases —
byte-for-byte the right scan. It reads NR_EXPORTS=0 because the memory IS 0. (The
earlier isolated-`.ll` GOTPCREL red herring only appears when the globals are made
`external`; in-module they are direct.)

### 4. "Force `linux_abi_lookup` native FIXES resolution" is a LAYOUT SHIFT, not a fix
- `KLLVM_FORCE_NATIVE="linux_abi_lookup"` (or `+linux_abi_exports_init`) →
  **unresolved=0, `relocations applied=14183 skipped=0`**, boot advances PAST
  kmod into userspace to **hamsh `[stage-01] main-enter`**.
- BUT it then dies at the **exact Phase-5j stage-01 SIGSEGV**: `[pf] user fault on
  unmapped va=0x0ed1da0`, `NO covering VMA`, `tree-find=0`, `pid 0 exited
  (code=139)`, `schedule: no live tasks; halting`. The wild store simply moved to
  a DIFFERENT `.bss` victim (task_table/vma_tree_root) once the export table was
  shifted out of its target range.
- **Control:** forcing an UNRELATED function (`_another_task_ready`) native does
  NOT fix resolution (still `skipped=3290`) — proving it is the *specific* `.bss`
  layout delta, not the function's own codegen. `exports_init` is LLVM in BOTH the
  fixed and broken builds and its population logic is address-independent, so the
  table IS populated then ZEROED (not never-populated); only its `.bss` address
  differs between the two layouts.

### 5. UNIFICATION + corrected record
The stage-01 wall, the pid=7 wall, and the new kmod/export-table wall are the
**SAME** deterministic, layout-sensitive bulk-`.bss` wild store (Phase 5g/5k/5m:
genuine physical zeroing, CPU store not DMA, invisible to `scan_oob.py`). Forcing
`memblock_alloc` (Phase 5m) or `linux_abi_lookup` (this phase) native only
RELOCATES the victims; it does not remove the store. **The LLVM lane reaches pid=7
in NO tested configuration** — it walls at whichever `.bss` global the store lands
on for the current layout. The brief's premise (pid=7 is now un-confounded, and
`_another_task_ready`/`do_rfork` is the blocker) does not hold: we never reach
userspace scheduling; the confounder (the wild store) is still live. `memblock_
alloc`-native's apparent Phase-5m win was itself a layout artifact.

### 6. Best next probe (improves on the documented dead-ends)
The export-table victim is a MUCH better instrumentation target than the
execve-timed task_table victim (Phase 5j needed elaborate time-bracketing): it is
zeroed EARLY (`[boot:35]`, ~serial line 400 — long past early boot's DR-clobber
window) at a FIXED symbol (`NR_EXPORTS` @ `0x05109c40` phys). Arm a QEMU physical
/ low-identity **hardware watchpoint on `0x05109c40` AFTER boot:34** (connect gdb,
run to the kmod_hello init_module return, THEN `watch`; the boot:35 store should
trip it — the Phase-5j/5k KVM-DR-clobber failure was for EARLY-armed watches). The
tripping RIP names the writing function directly → `clang -S` vs native objdump on
that store → the `ssa_llvm.ad` construct to fix (gate `ssa_mem_model`). Candidate
writers to disasm at boot:35 (all run between `exports_init` and the `#GP`):
`kmod_linux_load`'s `memset(base,0,span)` / `_bias_loaded` / `_copy_sections`
(linux_abi/loader.ad) and `_apply_relocations` — verify each section's
`sec_loaded_addr[i]` lands in the module window (`≥0xffffffff8c600000`), NOT a
biased-wrong low kernel `.bss` address.

Net: default lane unchanged (still walls at the kmod/export-table `#GP`; forcing
`linux_abi_lookup` native advances to the Phase-5j stage-01 SIGSEGV — neither
reaches pid=7). Native kernel boots fully (control). Native byte-identical (no
source touched this phase; only this doc). The wild store remains the single
open blocker; the `_another_task_ready` pid=7 theory is moot until it is fixed.

## Phase 5o — the export-table zero is PINNED IN TIME to the FIRST `kmod_linux_load` entry transition (boot:35.X); genuine physical zero with NO store on the synchronous path; watchpoint approach exhausted (three independent gdb failure modes) — writer narrowed but exact RIP not captured (evidence-backed, native-safe)

Executed the brief's Phase-5o plan (arm a HW watchpoint on the fixed export-table
phys addr after boot:34). The watchpoint approach is **not viable here** for three
compounding, independently-verified reasons (below). Pivoted to **layout-safe
`printk`-only source probes** (no new `.bss` global ⇒ `.bss` byte-identical ⇒ the
fixed-address victim does not move, verified: `bss=145864056` unchanged across
every probe build) and TIME-bracketed the zero to a single instruction transition
— a large advance over 5b–5n, which never localised it below "somewhere on the
execve/kmod path". All probes reverted; `git status` clean bar this doc; no
`codegen.ad`/`ssa*.ad`/kernel-`.ad`/`build_kernel_llvm.sh` change ⇒ native kernel
byte-identical by construction (kobjdiff PASS).

### 1. Reproduced the DEFAULT lane wall (KVM `-cpu host`, BIOS-GRUB-ISO, `-m 1024M`)
`[boot:35] linux_abi_exports_init` → later at `[boot:35.X]
modules_dep_load_with_deps("xhci_pci")` (which pulls **usbcore**, the FIRST
`kmod_linux_load`), `#GP` `rip=0xffffffff8c61a956`, `relocations applied=10893
skipped=3290`, export table physically empty. Boot ordering confirmed: the module
load is IN `start_kernel` (boot:35), BEFORE userspace (boot:37) — so this `#GP` is
NOT "past pid=7" (re-confirms 5n vs 5m).

### 2. The zero is bracketed to ONE instruction transition
Reading `NR_EXPORTS` (via a fixed accessor) at successive checkpoints:
- `linux_abi_exports_init` populates the table monotonically: after the 10 manual
  exports `NR=10`, after kthread `53`, after drm `2648`, **at exports_init END
  `NR=2756`.**
- `NR=2756` survives INTACT through `loader_init()`, the run-selftests scan, the
  cpio registrations, `modules_dep_init()`, the 4-deep `_md_walk_deps` recursion,
  `_md_find_ko`, and right up to and INCLUDING `_md_load_single`'s **`before-hook`
  / `after-cli` / `after-hookprint`** probes — the last statements before the
  loader-hook indirect call. `NR=2756` there.
- **At `kmod_linux_load`'s VERY FIRST source line, `NR=0`.** The line-stamp
  `printk_line_seq` (a co-located `.bss` global in `early_8250.ad`) simultaneously
  collapses `~434 → ~6`.

So the multi-global `.bss` zero happens in the window **{ `call *%rax`
(loader-hook dispatch in `_md_load_single`) → `kmod_linux_load` prologue → its
first `linux_abi_export_count()` }** — nothing else executes there.

### 3. Ruled OUT, decisively (each a separate probe/experiment)
- **Read-miscompile:** at `kmod_linux_load` entry the value is `0` read THREE
  ways — `linux_abi_export_count()`, a raw literal higher-half pointer
  `*(uint64*)0xffffffff85109c40`, AND the **direct-map alias**
  `*(uint64*)0xffff888005109c40`. All `0`. → genuine PHYSICAL zero, not a
  per-context read divergence and NOT a page-table/CR3 remap (the low-identity/
  direct-map alias reads 0 too).
- **Maskable IRQ:** wrapping the hook call in `local_irq_disable()` does NOT
  prevent it (`after-cli NR=2756`, entry `NR=0`). → synchronous or a
  non-maskable/exception source.
- **`do_page_fault`:** forcing it native (the 5e/5f suspect) does NOT help —
  entry `NR=0`, `skipped=3290`, same `#GP`. And `-d int` (TCG) shows the WHOLE
  boot takes essentially no exceptions in this window (`v=0e` page-fault count = 0;
  only one timer + the final wall `#GP`). → NOT `#PF`-triggered, NOT any exception.
- **The loader hook is correct:** printed at runtime, `kmod_linux_load_hook ==
  &kmod_linux_load` exactly (no trampoline / wrong-copy). `call *%rax` goes
  straight to `kmod_linux_load`, whose `-O0` prologue disassembles CLEAN
  (`sub $0x698,%rsp` + stack-only spills + `call export_count`) — **no store to
  `.bss`, no `rep stos`, no absolute-address store** before the `NR==0` read.
- **`module_map_alloc`/`memblock_alloc` base:** the usbcore module maps at the
  CORRECT high window (`virt=0xffffffff8c600000`, sections at `0x8c6…`), so the
  `memset(base,0,span)` targets the module, NOT the export table. Not the writer.

The paradox — a genuine physical multi-global `.bss` zero across a `call` to a
clean-prologue function, IRQs off, single CPU, no exception, no visible store —
is the finding: the writer is NOT any synchronous instruction on the pinned path
that static analysis or `-O0` disassembly can see. Reproduces identically under
**both KVM and TCG** (deterministic, not an accel quirk).

### 4. `kmod_linux_load` native = the export table SURVIVES → boot advances to the stage-01 residual
`KLLVM_FORCE_NATIVE="kmod_linux_load"`: entry `NR=2756`, **`relocations
applied=14183 skipped=0`**, usbcore + several further `.ko`s all resolve
`skipped=0`, the `#GP` is GONE, boot advances INTO userspace and dies at the
**exact Phase-5j/5n stage-01 SIGSEGV** (`[pf] user fault on unmapped va=0x0ed1da0
-> SIGSEGV`, `no live tasks; halting`). Contrast: `do_page_fault` native does
NOT move the wall at all. So `kmod_linux_load`-native produces the SPECIFIC
`.bss` layout delta that shifts the export table off the wild-store's FIXED target
(which then lands on `task_table`/`vma_tree_root` → stage-01) — the same
layout-shift signature 5m/5n documented for `memblock_alloc`/`linux_abi_lookup`.
i.e. the store's TARGET is a fixed (mis-computed) absolute address that fires at
the first-`kmod_linux_load`-entry TIME; whichever `.bss` global occupies that
address for the current layout is the victim. The store PERSISTS; forcing a
function native only relocates the victim (does NOT reach pid=7).

### 5. Why the watchpoint could not capture the RIP (all three verified)
- **KVM hardware breakpoints/watchpoints are DR-clobbered in early boot** (5j/5k):
  a SINGLE hbreak at `kmod_linux_load` fired ONCE (probe 1); every armed-at-reset
  hbreak/watch since (incl. multi-bp) was silently wiped before boot:35.
- **Software breakpoints cannot be inserted at the `-S` reset vector:** the
  higher-half target VA is unmapped before paging, so gdb's deferred int3 insert
  never takes — the bp never fires though the code runs (boot proceeds to the
  wall). Confirmed under both KVM and TCG.
- **Hybrid-link dead/live symbol-copy ambiguity:** `--allow-multiple-definition`
  resolves many globals to the NATIVE (never-executed) copy while the LIVE LLVM
  copy runs at a different, un-symboled address (verified: `nm`'s
  `linux_abi_exports_init`/`loader_init`/`_md_load_single` are DEAD copies — bps
  there never fire though the functions demonstrably run; only `kmod_linux_load`'s
  `nm` address is live, hook-confirmed). So even TCG `hbreak` on the `call *%rax`
  anchor never fired: that anchor is in the dead `_md_load_single` copy.
  A reliable LIVE anchor between "table populated" and the zero could not be
  obtained through the symbol table.

### 6. Force-native bisection of the pinned window + best next probe
Force-native results on the pinned window (all layout-invariant `skipped=`
readouts):
- `kmod_linux_load` native → **`skipped=0`**, export table survives, boot advances
  to the stage-01 SIGSEGV (§4) — but its own body disassembles clean, so this is
  the layout-shift that moves the export table off the fixed target, NOT a fix.
- `kernel_modules_dep__md_load_single` (the hook CALLER) native → **`skipped=3290`,
  same `#GP`** — NO change. → the writer is NOT in `_md_load_single`'s LLVM body /
  hook-call setup.
- `do_page_fault` native → **`skipped=3290`, same `#GP`** — NO change.

So the writer is NOT `_md_load_single`, NOT `do_page_fault`, NOT `kmod_linux_load`'s
body: it is confined to the `call *%rax`→`kmod_linux_load`-prologue transition (or
an off-path mechanism firing at that TIME) with a fixed absolute `.bss` target.
To get the RIP without the broken bp path: (a) full-speed TCG to the LIVE `kmod_linux_load`
entry (hbreak on the hook-confirmed `0x8042f0d0`, which DOES fire), then
`stepi`-scan the ~40 instrs of `_md_load_single`'s tail found by unwinding one
frame — TCG single-step at that point is cheap and DR-clobber-free. (b) OR a
QEMU record/replay (`-icount`, `rr`) to place a reverse-watchpoint on
`0x05109c40` and reverse-continue to the writing insn. The writer target is a
fixed absolute `.bss` address (`~0x05109c40` phys for the current default layout);
the `ssa_llvm.ad` construct to fix is whatever emits a store/clear to that fixed
address around the first `kmod_linux_load` call — NOT `do_page_fault`,
`memblock_alloc`, or `kmod_linux_load`'s own body (all cleared here).

Net: default lane unchanged (still walls at the kmod/export-table `#GP`; forcing
`kmod_linux_load` native — like `linux_abi_lookup`/`memblock_alloc` — advances to
the Phase-5j stage-01 SIGSEGV via a layout shift, not a fix; neither reaches
pid=7). Native kernel byte-identical (no compiler/kernel/build-script source
touched this phase; all probes reverted; `git status` clean bar this doc;
kobjdiff PASS). The wild store's exact writing instruction remains the single open
blocker; it is now pinned to the first-`kmod_linux_load`-entry TIME window with a
fixed absolute `.bss` target and every synchronous-instruction / IRQ / exception /
read-miscompile / mapping explanation on that path ruled out.

## Phase 5p — THE "WILD .bss STORE" DOES NOT EXIST: root cause is the HYBRID `--allow-multiple-definition` DUPLICATE-GLOBAL split (writer and reader bind DIFFERENT copies of the export table); FIXED by giving every global one definition — default lane now boots PAST the kmod #GP, past pid=7/rfork, to `start_kernel`'s `start_first_task` + `/bin/hamsh` execve (new furthest point)

Phases 5g–5o chased a "layout-sensitive wild `.bss` store" that zeroes the export
table at the first `kmod_linux_load`. **There is no such store.** Live-target gdb
(full-speed TCG, `hbreak` — which, unlike KVM hbreak, is NOT DR-clobbered and,
unlike sw-break, needs no int3 write into an unmapped higher-half VA) captured the
truth. The prior phases were reading a DEAD DUPLICATE copy of the global that is
trivially, permanently 0.

### 1. The tooling that finally worked (records for the next agent)
- `hbreak *<addr>` under **TCG** fires reliably at any VA once execution reaches
  it (QEMU checks a VA breakpoint list; no guest-DR, no memory write). The
  5j/5k/5o watchpoint dead-ends were KVM-DR-clobber and int3-into-unmapped, both
  TCG-`hbreak`-immune. nm's `kmod_linux_load` (`0xffffffff8042eff0` here) IS the
  live copy — `hbreak` there fired first try.
- QEMU TCG gdb **watchpoints are VIRTUAL-address** based (a watch on the
  higher-half VA does NOT catch a store through the low/alias VA of the same
  physical). This — plus the two-copy split below — is why every 5j–5o watchpoint
  "failed".

### 2. Disproof of the wild store (this build: NR_EXPORTS native-copy phys layout differs from 5o)
- `_add_export`/`linux_abi_exports_init` (the WRITERS) populate NR_EXPORTS/
  export_names at **`0xffffffff896c2002`/`0x896c200a`** (RIP-relative `lea`,
  disassembled from the live `_add_export`).
- A `watch *(int*)0xffffffff896c2002 if …==0` under TCG trips exactly ONCE — the
  legitimate early-boot `.bss` clear (`rep stos`, `rdi=__bss_start..__bss_end`,
  `rax=0`, RIP `0xffffffff80114018`) — and NEVER again through boot:35. i.e. the
  populated copy is written to 2756 and **is never zeroed**.
- At the `kmod_linux_load` entry `hbreak`: NR_EXPORTS **LLVM-copy `0x896c2002` =
  2756 (INTACT)**, native-copy `0x8510dc40` = 0. The "genuine physical zero" of
  5n/5o was a CR3-independent read of the *native* copy, which is 0 because it was
  never populated — not because anything wrote 0 to it.

### 3. Actual root cause — inconsistent binding of DUPLICATED globals
Both `kernel_main_llvm.o` (whole-kernel LLVM) and `native_main.o` (hybrid
fallback for the ~5 bailed fns) **define every module global** (NR_EXPORTS,
export_names, task_table, …) as a strong `dso_local` symbol. `ld
--allow-multiple-definition` resolves **each relocation independently**, so two
references to the *same* `@NR_EXPORTS` — even within the same LLVM object — bind
to DIFFERENT copies (`objdump` proof, this build):
- `_add_export` (writer): `lea …# 0xffffffff896c2002 <NR_EXPORTS>` → LLVM copy.
- `linux_abi_lookup` (reader): `mov …# 0xffffffff8510dc40 <NR_EXPORTS>` and
  `mov $0xffffffff8510dc50,%rax` (export_names) → NATIVE copy.

So `exports_init` fills copy A to 2756 while `linux_abi_lookup` scans copy B
(empty). Every Linux-ABI symbol resolves to 0 → 3290 relocations skipped →
usbcore `init_module` calls an unrelocated site → `#GP rip=0xffffffff8c61a956`.
The `.ll` IR for both references is byte-identical (`ptrtoint [N x i8]*
@NR_EXPORTS to i64`) — the emitter is CORRECT; the defect is purely the hybrid
link. This also explains every 5m/5n/5o "force fn native RELOCATES the victim":
forcing a fn native re-shuffles which copy each surviving reference binds to.

### 4. The fix — one definition per global (opt-in lane only)
`scripts/kllvm_externalize_dupglobals.py` (wired into `build_kernel_llvm.sh`
steps 1c/1d): after building `native_main.o`, rewrite the LLVM object's
DEFINITION of every global that `native_main.o` ALSO defines into an `external`
DECLARATION (`@g = external dso_local global [N x i8]`). native_main.o becomes
the SOLE definer, so every reference (LLVM- and native-compiled alike) binds to
that one copy. Globals defined ONLY in the LLVM object (`__stack_chk_guard`,
`_l_PCI_CAP_ID_MSIX`, …) stay defined; `.Lstr*` literals are `internal` and never
match. `dso_local` is kept so addressing stays direct (no GOT). 10076 duplicated
globals collapse to external. **No compiler (`adder/compiler/*`) or kernel `.ad`
source is touched** — the change is the opt-in build script + a generated-`.ll`
rewrite, so the native kernel is byte-identical by construction (kobjdiff PASS,
`git diff` = `scripts/build_kernel_llvm.sh` + new helper only).

### 5. Result — new furthest point (verified by `grep -a` on the serial log)
Default lane (`memblock_alloc` native, KVM `-cpu host`, BIOS-GRUB-ISO, `-m 1024M`):
`_add_export` and `linux_abi_lookup` now both reference the single
`NR_EXPORTS @0xffffffff85146002`. Boot:
`kmod_linux: relocations applied=14183 **skipped=0**` (usbcore) — and skipped=0
for all four loaded modules (14183/11867/340/12247), `init_module` called and
returns, **the kmod/export-table `#GP` is GONE**. Boot then advances through
`[boot:37] rfork` (past the Phase-5d/5k pid=7 wall — it dispatches), the trap
installers, `[boot:41.5] himem_late_report`, **`[boot:42] start_first_task`**,
and `execve`s **`/bin/hamsh`** (`jumping to 0x0000000000400012`). It then hits a
NEW, unrelated wall: `Kernel panic: schedule: dispatch into task with
uninitialized sp` — the next blocker (first-task/scheduler sp init), well past
everything 5b–5o reached. The `memblock_alloc`/`linux_abi_lookup`/`kmod_linux_load`
force-native defaults are now moot layout-artifacts and can be revisited.

Net: the single open blocker of 5b–5o (export table empty → kmod `#GP`) is FIXED
at root; it was a hybrid-link duplicate-global binding bug, NOT a codegen wild
store. Native kernel byte-identical (opt-in build-script + generated-`.ll` rewrite
only; no compiler/kernel source; kobjdiff PASS). New furthest point: `boot:42
start_first_task` + `/bin/hamsh` execve, walling at scheduler `uninitialized sp`.

## Phase 5q — ROOT-FIXED: the `uninitialized sp` panic is a SIGNED-vs-UNSIGNED compare miscompile in the SSA/LLVM backend (`ssa_expr_sgn` ignored struct-member `.field` signedness → `icmp slt` where native uses `icmp ult`); fixed IN `ssa.ad` → LLVM kernel now boots to the interactive `hamsh$` prompt (full userspace, pids 7–26), matching native

Phase 5p left the lane walling at `Kernel panic: schedule: dispatch into task
with uninitialized sp`. This is a GENUINE codegen miscompile in the SSA/LLVM
backend (NOT another hybrid-link split), root-caused to an instruction and fixed
in `adder/compiler/ssa.ad`. The LLVM kernel now boots all the way to the
interactive shell prompt.

### 1. The panic is a FALSE-POSITIVE guard: the sp is valid, the COMPARE is wrong
`schedule()` guards against a garbage saved sp with
`if task_table[nxt].sp < cast[uint64](0x100000): panic(...)` (`kernel/sched/core.ad`
line ~5201). The panic's own diagnostics printed the sp it was rejecting:

```
SWITCH-BAD-SP: cpu=0 nxt=5
SWITCH-BAD-SP: sp=0xffff88800a852f48 pid=5
SWITCH-BAD-SP: nxt.state=2 on_cpu=1
SWITCH-BAD-SP: rq_cpu=0 kstack_top=0xffff88800a853000
```

`sp=0xffff88800a852f48` is a perfectly VALID direct-map kstack address
(`kstack_top - sp = 0xB8` = a legitimate initial iret frame). It is NOT
`< 0x100000`. Yet the guard fired — because the compare was emitted as a SIGNED
comparison, and `0xffff88800a852f48` has bit 63 set, so as a signed i64 it is
NEGATIVE and therefore "< 0x100000". This is the FIRST `schedule()` dispatch
whose `nxt.sp` is a high-half/direct-map (bit-63-set) address, which is why the
bug is latent until exactly this point (`start_first_task` hands off via
`enter_first_task_sysret`, bypassing the guard; the panic is the first real
cross-task `schedule()`).

### 2. Pinned to the instruction: `icmp slt` vs `icmp ult` in the emitted `.ll`
In `build/kllvm/kernel_main.ll`, `@schedule`'s guard compare emitted
`%v492 = icmp slt i64 %v490, 1048576` (1048576 = 0x100000) — **signed**. The
LLVM emitter (`ssa_llvm.ad` `ll_put_icmp_pred`) faithfully renders `sv_c[v]`,
the setcc opcode byte carried in the SSA IR; the IR itself held `0x9C` (setl,
signed) where it should hold `0x92` (setb, unsigned).

### 3. Root cause — `ssa_expr_sgn` has no ND_MEMBER arm
`ssa.ad` selects the compare's setcc via
`ssa_cmp_setcc(op, ssa_expr_sgn(lnode), ssa_expr_sgn(rnode))` (line ~3210), and
`rel_setcc` only switches to the UNSIGNED family when an operand's signedness
tristate is `1` (unsigned). For `task_table[nxt].sp < 0x100000` the left operand
is a struct-member access (`.sp`, a `uint64` field) and the right is a literal.
But `ssa_expr_sgn` (the SSA backend's shallow operand-signedness helper) only
handled ND_IDENT / ND_CALL / ND_INDEX / ND_UNARY(deref) — it had **no ND_MEMBER
arm**, so `task_table[nxt].sp` returned `0` (unknown), the literal returned `0`,
and `rel_setcc(0x9C, 0, 0)` kept the SIGNED default `0x9C`. The native backend
(`codegen.ad` `expr_signedness`) DOES have an ND_MEMBER arm
(`member_scalar_signedness` → the field's declared `uint64` signedness = 1 =
unsigned → `setb`/`ult`), which is exactly why the NATIVE kernel compiles this
compare correctly and boots fully. Pure SSA/LLVM-path divergence; the native
`codegen.ad` path was always correct.

### 4. The fix (native-safe by construction)
Added the missing ND_MEMBER arm to `ssa_expr_sgn` in `ssa.ad`, delegating to the
SAME `codegen.ad` helper the native path uses:

```
    if k == ND_MEMBER:
        return member_scalar_signedness(node)
```

(plus importing `member_scalar_signedness` from `compiler.codegen`). This makes
the SSA/LLVM operand-signedness resolution mirror native exactly. The change is
confined to `ssa.ad`'s LLVM/`--opt` signedness helper — the native `codegen.ad`
compare-selection path is untouched, so the native kernel is byte-identical.

### 5. Native-safety gates — ALL PASS (verbatim)
- `scripts/test_native_vs_seed_kobjdiff.sh`:
  `[kobjdiff] kernel FUNCs compared: 11064` /
  `[kobjdiff] PASS — zero semantic kernel divergences across 11064 matched functions` /
  `[kobjdiff] PASS — native kernel codegen matches the seed (semantic).`
  (`git diff --stat` = `adder/compiler/ssa.ad | 10 ++++++++++` ONLY —
  `codegen.ad` does NOT appear in the native diff.)
- `scripts/fuzz_adder_diff.sh 7`: `[fuzz_adder_diff] PASS`
  (`python-backend miscompiles: 0`, `tooling/run errors: 0`).
- `ADDER_OPT2=1 scripts/fuzz_adder_diff.sh 7`: `[fuzz_adder_diff] PASS`
  (`codegen.ad accepted: 500 (100.0%)`, `of accepted, CORRECT: 500 (100.0%)`,
  `MISCOMPILED: 0`).
- `scripts/bench_llvm.sh`: `[bench_llvm] LLVM compiled 8/8 kernels; bailed: [];
  wrong: []` (all 8 kernels `AGREE`, `LLVM=OK`; geomean 0.88x gcc-O2).

### 6. Result — new furthest point: the interactive `hamsh$` prompt (grep-verified)
Default lane (`memblock_alloc` native, KVM `-cpu host`, BIOS-GRUB-ISO,
`-m 1024M`), `grep -a` on the serial log:
- `@schedule`'s guard now emits `%v492 = icmp ult i64 %v490, 1048576` (unsigned).
- ZERO `uninitialized sp` / `SWITCH-BAD-SP` lines.
- Boot advances through `start_first_task`, `/bin/hamsh` execve, hamsh stages
  01–05, `M16.35 shell ready`, sources `/etc/rc.boot`, `rfork: child created,
  pid=7` **dispatched**, then pid=8, 9, 10, 11, and pids 12–26, `stage-06 rc-done`,
  `stage-07 loop-enter`, and reaches the interactive **`hamsh$ [hamsh:stage-08]
  ed-readline-first`** prompt — the shell is up and blocking for input. This
  MATCHES the NATIVE kernel's full boot (the Phase-5n control) — the LLVM lane now
  reaches userspace steady-state.

Net: the `uninitialized sp` blocker is FIXED at root — a signed/unsigned compare
miscompile in the SSA/LLVM backend's struct-member signedness resolution, fixed in
`ssa.ad` (10-line ND_MEMBER arm + import). Native kernel byte-identical (kobjdiff
PASS, diff = `ssa.ad` only; codegen.ad NOT in the native diff). All four
native-safety gates green. New furthest point: **interactive `hamsh$` prompt
(stage-08), full userspace with pids 7–26** — the LLVM-compiled kernel now boots
to the shell, on par with native. This is the ARM-unlock milestone: a whole-kernel
LLVM-compiled Hamnix booting to userspace.

## Phase 5r — the `-O2` lane: label-collision BUILD-BLOCKER ROOT-FIXED in the emitter (`.L` → `${:uid}`); `-O2` now COMPILES + boots; two deeper `-O2`-only codegen blockers pinned (evidence-backed, native-safe)

`-O2` is the point of the LLVM backend (native-SSA ≈5.6× slower than gcc-O2;
LLVM -O2 ≈ parity). Phases 5b–5q ran the lane at `-O0` (correctness only). This
phase brings up `-O2`. The documented `-O2` build-blocker — clang's integrated
assembler rejecting the rdrand/rdseed inline-asm `.L` labels when it inlines the
same asm template at multiple call sites — is **root-fixed in the Adder LLVM
emitter** (not worked around in the build script). The `-O2` object now compiles
and links; the lane boots and, past the label fix, surfaces two SEPARATE
`-O2`-only codegen defects that `-O0` hides. Only `adder/compiler/ssa_llvm.ad`
changed (the LLVM emitter's asm-template string writer) — the native `codegen.ad`
path is untouched, so the native kernel is byte-identical by construction and all
four native-safety gates are green.

### 1. Reproduced the exact `-O2` collision
`LLVM_CLANG_OPT=-O2 scripts/build_kernel_llvm.sh` failed in clang's integrated
assembler:
```
<inline asm>:3:5: error: symbol '.Lrdrand_retry' is already defined
<inline asm>:8:5: error: symbol '.Lrdrand_ok' is already defined
<inline asm>:11:5: error: symbol '.Lrdrand_done' is already defined
<inline asm>:3:5: error: symbol '.Lrdseed_retry' is already defined
```
Source: `sys/src/9/port/devrandom.ad` `_rdrand64`/`_rdseed64` carry
`asm_volatile("... .Lrdrand_retry: ... jc .Lrdrand_ok ...")` retry loops with
FIXED `.L` labels. At `-O0` the two asm-bearing functions are out-of-line (one
instantiation each → labels unique). At `-O2` clang inlines them into their
callers, emitting the same template — and hence the same fixed `.L` labels —
multiple times → "symbol already defined". This is a general emitter-correctness
bug, not an `-O0`-vs-`-O2` policy: any inline-asm template with a local label is
unsafe to instantiate more than once.

### 2. Root fix — uniquify local labels with LLVM's `${:uid}` (`ssa_llvm.ad`)
The emitter renders zero-operand inline asm verbatim through
`ll_put_asm_string` (the double-quoted template of `call void asm sideeffect`).
Added a `.L<ident>` recogniser there: every GAS local label (`.L` is the GAS
local-symbol prefix, so any `.L<ident>` in a body is a local label) is emitted
verbatim followed by LLVM's `${:uid}` substitution token, which expands to a
per-asm-instantiation-unique integer. A label's definition and its references
share the instantiation → same uid → still matched; distinct inlined copies get
distinct uids → no collision. The `${:uid}` bytes are emitted RAW (bypassing the
`'$' → '$$'` literal-doubling) because there `$` IS the operand-substitution
escape we want. Real globals (e.g. `hwrng_scratch(%rip)`) are never `.L`-prefixed
and are left untouched. Emitted result:
```
.Lrdrand_retry${:uid}:  ...  jc .Lrdrand_ok${:uid}  ...  loop .Lrdrand_retry${:uid}
```
This is ARM-relevant too (label uniquification is a general asm-emitter fix, not
x86-specific). Rebuilt `host_ac` (the `.ll` is baked from `ssa_llvm.ad`), re-emitted:
`clang-19 -O2 -c -mcmodel=kernel` now produces a valid ELF64 relocatable; a
control build with the `${:uid}` tokens stripped back to fixed labels reproduces
the exact 4-error collision. Fix confirmed necessary AND sufficient for the label
blocker.

### 3. Native-safety gates — ALL PASS (verbatim)
- `scripts/test_native_vs_seed_kobjdiff.sh`:
  `[kobjdiff] PASS — zero semantic kernel divergences across 11064 matched
  functions` / `[kobjdiff] PASS — native kernel codegen matches the seed
  (semantic).` (`git diff --stat` = `adder/compiler/ssa_llvm.ad | 36 +++…` ONLY —
  `codegen.ad` does NOT appear in the native diff.)
- `scripts/fuzz_adder_diff.sh 7`: `[fuzz_adder_diff] PASS` (`MISCOMPILED: 0`,
  `python-backend miscompiles: 0`, `tooling/run errors: 0`).
- `ADDER_OPT2=1 scripts/fuzz_adder_diff.sh 7`: `[fuzz_adder_diff] PASS`
  (`codegen.ad accepted: 500 (100.0%)`, `of accepted, CORRECT: 500 (100.0%)`,
  `MISCOMPILED: 0`).
- `scripts/bench_llvm.sh`: `[bench_llvm] LLVM compiled 8/8 kernels; bailed: [];
  wrong: []` (all 8 `AGREE`, `LLVM=OK`; geomean 0.88× gcc-O2).

### 4. Boot furthest points (both grep-verified on the serial log)
- **`-O0` lane (regression check — STILL boots):** default build
  (`memblock_alloc` native, KVM `-cpu host`, BIOS-GRUB-ISO, `-m 1024M`),
  `grep -a`: `[hamsh] M16.35 shell ready` → `rfork: child created, pid=7` …
  through pid=26 → `[hamsh:stage-06] rc-done` → `[hamsh:stage-07] loop-enter` →
  `hamsh$ [hamsh:stage-08] ed-readline-first`. Identical to Phase 5q. No
  regression from the emitter change.
- **`-O2` lane (new):** BUILDS (previously could not compile at all) and boots
  through the entire kernel init battery to boot-stage 32, walling at the
  `p9_smoke_test` 9P handshake:
  ```
  [000397] [p9smoke] pipes tx=0 rx=1
  [000399] TRAP: vector 0x0e err=0x10 rip=0xffffffff00000000
  ```
  a page fault on an **instruction fetch** (`err` bit 4) at `rip=
  0xffffffff00000000` — a `call` through a function pointer that `-O2`
  miscompiles to `0xffffffff00000000` (high dword `0xffffffff`, low dword 0). This
  is a SECOND, independent `-O2`-only blocker, unrelated to labels.

### 5. The second `-O2` blocker — pinned to the 9P-handshake indirect-call path (NOT p9_smoke_test / _smoke_pump_call)
`-d int,cpu_reset` at the fault: `IP=0008:ffffffff00000000 pc=ffffffff00000000`,
`RDI=0xffffffff8557e69b RSI=0xffffffff856044c4 RBX=RCX=RDX=0x13`. `nm` maps
`RSI` INTO `p9smoke_buf` (`p9smoke_buf + 0x13`) — so the crashing call is a helper
in the p9 attach/codec path taking a `(ptr, &p9smoke_buf[0x13], len=0x13)`-shaped
arg set through a function pointer whose value is wrong. Single-variable
force-native bisection (`KLLVM_FORCE_NATIVE`) RULES OUT the obvious two:
forcing `p9_smoke_test` native (it computes `&p9smoke_pump` and drives the
handshake) AND forcing `_smoke_pump_call` native (the `hookfn(slot)` indirect
trampoline in `9p_client.ad`) EACH still trap identically at
`rip=0xffffffff00000000`. So the miscompiled instruction is in a deeper LLVM
callee common to all builds (the p9 codec / attach-run path), not in either the
funcaddr producer or the trampoline. Signature (`0xffffffff00000000`) points at a
function-pointer/indirect-call target materialisation where `-O2` drops the low
32 bits — the exact class the ARM retarget will also depend on. Open
`ssa_llvm.ad` defect (gate `ssa_mem_model`); the precise construct is not yet
isolated to one instruction.

### 6. A THIRD `-O2`-only blocker sits behind the second — in the rfork/COW page path
To measure how far the rest of the `-O2` kernel is clean, a THROWAWAY experiment
(reverted) stubbed the `p9_smoke_test()` boot-stage-32 call. With p9 out of the
way the `-O2` kernel advances all the way to userspace: `[hamsh] M16.35 shell
ready` → `rc.boot: device binds applied` → `rfork: child created, pid=7`. Then a
DIFFERENT `-O2`-only defect fires: a `[pa-corrupt] free of wild addr
0x00000000004790XX order=0 — ignoring` storm over the hamsh demand-VMA region
`[0x479000,…)` (the pages the forked child should COW), ending in a `trap-diag`
one-shot halt. `-O0` runs this identical rfork/COW/page-free path cleanly to
stage-08, so this too is `-O2` surfacing a latent codegen divergence (page-alloc
free-list / COW pointer arithmetic), NOT a logic bug. Two distinct `-O2`-only
codegen defects (indirect-call target truncation; wild page-free in rfork/COW)
therefore remain between the label fix and a full `-O2` boot.

### 7. Size/perf signal
`-O2` kernel `.text` = 54,321,544 B vs `-O0` = 57,419,016 B — **3.1 MiB (~5.4%)
smaller** even with the two force-native hybrid bodies still `-O0`; the
whole-kernel `-O2` compile is ~2 min. (No boot-to-steady-state `-O2` runtime
number yet — the lane does not reach userspace until the §5/§6 defects are
fixed.)

### Net
The documented `-O2` label-collision BUILD-BLOCKER is ROOT-FIXED in the emitter
(`.L` → `.L…${:uid}`), general and ARM-relevant; the `-O2` lane now compiles,
links, and boots (furthest `-O2` point: boot-stage-32 p9_smoke handshake; with p9
stubbed, `-O2` reaches `M16.35 shell ready` + `rfork pid=7`). `-O0` still boots to
the full interactive `hamsh$` stage-08 prompt (no regression). Native kernel
byte-identical (kobjdiff PASS 0/11064, diff = `ssa_llvm.ad` only; `codegen.ad`
NOT in the native diff); all four native-safety gates green. Two deeper
`-O2`-only codegen defects are pinned for the next agent: (a) an indirect-call
target truncated to `0xffffffff00000000` in the 9P codec/attach path (not
`p9_smoke_test`/`_smoke_pump_call` — bisection-excluded), and (b) a wild
page-free storm over the COW demand-VMA on the rfork path.

## Phase 5s — the `-O2` lane BOOTS TO USERSPACE: both pinned `-O2`-only blockers ROOT-FIXED in the emitter (struct-local alloca under-size; over-promised global `align 16`); `-O2` now reaches the interactive `hamsh$` stage-08 prompt, FULL parity with `-O0` (evidence-backed, native-safe)

Phase 5r pinned two `-O2`-only codegen defects between the label fix and a full
`-O2` boot. Phase 5s ROOT-FIXES BOTH in the Adder LLVM lane — one in the SSA
layer (`ssa.ad`), one in the LLVM emitter (`ssa_llvm.ad` + the externalize
helper). The `-O2` kernel now boots the whole init battery → `[p9smoke] PASS` →
`[hamsh] M16.35 shell ready` → `rfork` pids 7–26 → `[hamsh:stage-06] rc-done` →
`[hamsh:stage-07] loop-enter` → `hamsh$ [hamsh:stage-08] ed-readline-first`,
byte-for-byte the same furthest point the `-O0` lane reaches (Ph5q). Native
codegen is untouched (both fixes are LLVM-path-only), so the native kernel is
byte-identical (kobjdiff PASS 0/11064) and all four native-safety gates are
green.

### 1. Blocker #1 was NOT an indirect-call miscompile — it is a STRUCT-LOCAL STACK OVERFLOW that corrupts a saved return address
Phase 5r's framing (an indirect-call target materialised with its low 32 bits
dropped) is DISPROVEN. Full instrumentation of the `0xffffffff00000000` #PF:
- A temporary richer `do_trap` (idt_asm.S passes the exception frame base; the
  handler dumps the saved GPRs + a 16-deep stack walk) showed the crashing frame
  is the LLVM 9P **responder** (`p9smoke_pump → _serve_one → _serve_tversion`),
  reached from the NATIVE `_rpc_exchange → _smoke_pump_call` smoke pump. Saved
  `rsi = &p9smoke_buf+0x13`, `rdx=rcx=0x13` (the 19-byte Tversion), `rax=0`.
- The QEMU monitor read of the smoke-pump hook at the fault
  (`xp /2gx &p9c_smoke_pump_hook`) returned `0xffffffff80320120` — the CORRECT
  `&p9smoke_pump`. The hook is intact; the indirect call through it is fine. So
  the fault is NOT the hook / not an indirect-call target at all.
- `objdump` of EVERY responder/codec function (`_serve_one`, `_drain_tmsg`,
  `_serve_tversion`, `_send_rmsg`, `p9_emit_rversion`, `p9_decode_tversion`,
  `p9_cursor_init`, `pipe_read/write`) shows **zero** indirect `call *`/`jmp *`.
  The faulting instruction is a `ret` returning to a CORRUPTED saved return
  address: a real `0xffffffff80xxxxxx` return address with its LOW dword zeroed →
  `0xffffffff00000000` (#PF, instruction fetch, `err=0x10`).

Root cause, pinned to one instruction. `P9Cursor` = `{buf:Ptr, cap:u64, pos:u64,
err:i32}` = 32 bytes. In `_serve_tversion` the local `c: P9Cursor` got
`%t6 = alloca [8 x i8]` — an EIGHT-byte slot for a 32-byte struct. The inlined
`p9_cursor_init(&c,…)` member stores land at `c+0/+8/+16/+24`; at `-O2` the tight
frame (`push %rbx; sub $0x10,%rsp`) places that slot flush against the saved
return address, so `c.pos` at `0x10(%rsp)` clobbers saved `%rbx` and
`movl $0x0, 0x18(%rsp)` (writing `c.err=0`) zeroes the low dword of the SAVED
RETURN ADDRESS. `ret` then jumps to `0xffffffff00000000`. At `-O0` LLVM's loose
frame padding put slack between the slot and the return address, so the same
over-write landed in dead bytes — which is exactly why `-O0` hid it.

The under-size originates in `ssa.ad::ssa_intern_local`: a struct/class-typed
local has no dedicated branch and falls through to the scalar path, where
`sz = prim_type_size(tnode)` returns 8 for a struct-named type and the alloca is
sized `ssa_ensure_slot(nid, sz)` = 8. Fix: a struct-local branch sizes the slot
to the full `st_total[struct]` (32 for `P9Cursor`). Native path is byte-
identical — an address-taken struct local still bails to `codegen.ad` (`if
ssa_mem_model == 0: ssa_set_bail(SBR_NONPROMOTABLE)`) exactly as the scalar
non-promotable case did, so `codegen.ad` never sees the new branch. Post-fix the
IR carries `%t6 = alloca [32 x i8]` and `-O2` prints `[p9smoke] PASS`.

### 2. Blocker #2 is an OVER-PROMISED global ALIGNMENT — `align 16` in the IR vs BYTE-packed native globals → clang `-O2` emits `movaps` on a mis-aligned global → #GP
With blocker #1 cleared, `-O2` advanced to `M16.35 shell ready` + `rfork pid=7`,
then a `[trap-diag]` one-shot halt on a **#GP (vector 0x0d)** at
`rip=…802a32b0`, `code@rip = 0f 29 40 10` = `movaps %xmm0,0x10(%rax)`. The
function is `umdf_task_cleanup`, zeroing a global buffer at `0xffffffff84e384d4`
with a `xorps`/`movaps` loop — but `0x…84e384d4 mod 16 = 4`, so the ALIGNED SSE
store `#GP`s. Root cause: the emitter (`ssa_llvm.ad`) declared EVERY module
global `, align 16`, and the externalize helper stamped the externalized
(native-defined) globals `align 16` too. In the native-hybrid link
`native_main.o` is the SOLE definer of those globals and the native backend packs
them at BYTE granularity — a global can sit at any address mod 16. `align 16`
LIES to clang; at `-O2` it vectorises a global-zeroing loop into aligned
`movaps`, which faults on the real sub-16-aligned address. (`-O0` doesn't
vectorise → scalar stores → no fault, which is why `-O0` never hit it.) Fix:
emit `, align 1` in BOTH places (the honest bound for byte-packed native
globals); clang then uses unaligned (`movups`) / scalar stores that are correct
at any alignment. Post-fix `-O2` clears the #GP and runs to stage-08.

Note on the `[pa-corrupt] free of wild addr …` storm: this is PRE-EXISTING and
NON-FATAL, NOT a blocker. A clean `-O0` build (pre- AND post-Phase-5s) emits the
IDENTICAL storm (5655 `— ignoring` lines) yet still reaches stage-08 — Phase 5r
§6's "the `-O0` path runs cleanly" was imprecise (the storm was always there, it
just never halts). The FATAL `-O2` symptom Ph5r attributed to the rfork/COW path
was the `movaps` #GP of §2, now fixed. (The wild-free storm — the COW forked-
range release freeing user VAs as if physical frames — remains an open COSMETIC
item common to both lanes; it does not gate the boot.)

### 3. Native-safety gates — ALL PASS (verbatim)
- `scripts/test_native_vs_seed_kobjdiff.sh`:
  `[kobjdiff] kernel FUNCs compared: 11064` /
  `[kobjdiff] PASS — zero semantic kernel divergences across 11064 matched
  functions` / `[kobjdiff] PASS — native kernel codegen matches the seed
  (semantic).` (`git diff` = `ssa.ad`, `ssa_llvm.ad`,
  `kllvm_externalize_dupglobals.py` — `codegen.ad` is NOT in the native diff.)
- `scripts/fuzz_adder_diff.sh 7`: `[fuzz_adder_diff] PASS` (`MISCOMPILED: 0`,
  `python-backend miscompiles: 0`, `tooling/run errors: 0`).
- `ADDER_OPT2=1 scripts/fuzz_adder_diff.sh 7`: `[fuzz_adder_diff] PASS`
  (`codegen.ad accepted: 500 (100.0%)`, `of accepted, CORRECT: 500 (100.0%)`,
  `MISCOMPILED: 0`).
- `scripts/bench_llvm.sh`: `[bench_llvm] LLVM compiled 8/8 kernels; bailed: [];
  wrong: []` (all 8 `AGREE`, `LLVM=OK`; geomean 0.90× gcc-O2).

### 4. Boot furthest points (both grep-verified on the serial log)
- **`-O0` lane (regression check — STILL boots):** default build (`memblock_alloc`
  native, KVM `-cpu host`, BIOS-GRUB-ISO, `-m 1024M`), `grep -a`:
  `[p9smoke] PASS` → `[hamsh] M16.35 shell ready` → `rfork: child created,
  pid=7` … pid=26 → `[hamsh:stage-06] rc-done` → `[hamsh:stage-07] loop-enter` →
  `hamsh$ [hamsh:stage-08] ed-readline-first`. Identical to Phase 5q/5r; the
  `alloca`/`align` fixes are neutral on `-O0` (identical 5655-line pa-corrupt
  storm pre/post fix).
- **`-O2` lane (NEW — full userspace):** same build config, `LLVM_CLANG_OPT=-O2`:
  `[p9smoke] PASS` → `[hamsh] M16.35 shell ready` → `rfork` pids 7–26 →
  `[hamsh:stage-06] rc-done` → `[hamsh:stage-07] loop-enter` →
  `hamsh$ [hamsh:stage-08] ed-readline-first`. FULL parity with `-O0` (Ph5r
  walled at boot-stage-32 p9_smoke; both `-O2`-only blockers now fixed).

### Net
Both Phase-5r `-O2`-only blockers are ROOT-FIXED in the Adder LLVM lane:
(a) struct/class-typed local allocas are now sized to the full struct byte size
(`ssa.ad`), ending the `P9Cursor` stack overflow that zeroed a saved return
address (the `0xffffffff00000000` #PF — NOT an indirect-call miscompile as
Ph5r hypothesised); (b) module globals are declared `align 1` not `align 16`
(`ssa_llvm.ad` + externalize helper), matching the byte-packed native-hybrid
layout so clang `-O2` stops emitting `movaps` on mis-aligned globals (the
`umdf_task_cleanup` #GP). The `-O2` LLVM kernel now boots to the interactive
`hamsh$` stage-08 prompt, full parity with `-O0`; `-O0` still boots there too (no
regression); native kernel byte-identical (kobjdiff 0/11064); all four
native-safety gates green. Both fixes are ARM-relevant (struct frame sizing and
honest global alignment are target-independent emitter correctness).
