# Hamnix TODO

What's still open. **For what's shipped, read [`STATUS.md`](STATUS.md)** —
it's append-only, dated, and the source of truth. Completed items live
there, not here; this file stays lean.

Pointers:
- Design: [`docs/architecture.md`](docs/architecture.md),
  [`docs/native-api.md`](docs/native-api.md) (Layer 1 Plan 9 syscalls),
  [`docs/hamUI.md`](docs/hamUI.md), [`docs/security.md`](docs/security.md).
- Snapshot: [`README.md`](README.md). Onboarding: [`CONTRIBUTING.md`](CONTRIBUTING.md).
- Latest audits (2026-06-13): [gap vs Linux](docs/audit_gap_vs_linux_2026-06-13.md),
  [arch shortcuts](docs/audit_arch_shortcuts_2026-06-13.md).

Markers: `[ ]` open · `[~]` in flight.

---

## ⚠ Direction (2026-06-20)

**Goal sharpened:** Hamnix is a **good desktop _and_ server OS in the
shape of Plan 9** — not a general "Linux competitor." That target makes
several architectural calls for us (below). Plan 9 spine is real and
held; the next push is foundational hardening, not new surface area.

### ⚠ Compiler strategy REDIRECT (2026-06-21) — Python is the SEED; the optimizer lives in Adder

The original plan put the optimizer in the Python compiler (`codegen_x86.py`).
**Reversed.** The Python compiler is a **bootstrap seed: correct, not fast.** Its
only job is to compile the real (Adder-written) compiler once. Pouring a permanent
optimizer into it means (a) writing the whole IR + passes TWICE (Python now, Adder
later), (b) two compilers that silently diverge — the fuzzer already caught **6
miscompiles** in `codegen.ad` from exactly that drift, and (c) an optimizer that
never runs on-device and proves nothing about the self-hosted toolchain (the
credibility demo). Perf is orthogonal to compiler language — the generated-code
quality lives in the *passes*, so there's no perf reason to keep them in Python.

**New ordering / state:**
1. **Adder Linux target (Tier 2)** — ✅ DONE. `x86_64-linux` freestanding target;
   host-run Adder does real syscalls.
2. **Compiler fuzzer** — ✅ DONE. Predicted-output oracle; found+fixed 3 backend
   miscompiles; 0 over 10k programs. The permanent correctness gate + the
   differential oracle (`--diff-target`).
3. **Self-hosting cutover — NOW THE LEAD COMPILER TRACK.** Finish `codegen.ad` to
   FULL parity with `codegen_x86.py`, then build the `.ad` compiler as an
   `x86_64-linux` host binary so it drives the build with Python as a one-time seed.
   This is the prerequisite for the real optimizer AND the credibility milestone.
   - ✅ **Multi-dimensional array globals** (`Array[N, Array[M, T]]`) — DONE.
     `codegen.ad` now lays out the full nested type into `.bss`, carries the
     array type node per global, and indexes level-by-level (outer index scales
     by the nested row stride, inner by the scalar element). Root fix: the
     index-scale helper handled only power-of-2 widths; added an `imulq` fallback
     for arbitrary row strides (e.g. 24). The differential fuzzer now generates
     2-D grid traffic in BOTH modes; `scripts/fuzz_adder_diff.sh` accept-rate is
     100% with 0 miscompiles. The differential gate now exercises EVERY construct
     the default generator emits (subset==default).
   - ✅ **Parity gaps CLOSED (2026-06-21).** Multi-base receiver-offset bump
     LANDED in `codegen.ad` (`class_end_of_fields`/`receiver_offset_for` +
     `emit_add_imm_rax` bump in `gen_method_call`; fuzzer emits a
     `MDerived(MBase0,MBase1)` inherited-from-second-base method every program).
     By-value struct params/returns REJECTED in lockstep in BOTH backends
     (Adder has no by-value aggregate ABI by design; the seed previously
     SILENTLY miscompiled them — now `CodeGenError` / `cg_fail(9)`). SysV XMM
     extern-FP path documented as intentionally GP-uniform/unused (no extern
     float call exists). (`codegen.ad` already covers 1-D/2-D/scalar globals of
     every width, casts, compares, div/mod, while/for/do-while loops,
     if/elif/else, break/continue, helper calls, pointers, syscalls,
     classes/methods + multi-base dispatch, structs + member access, and scalar
     SSE float32/float64.)
   - ✅ **CUTOVER DRY-RUN PROVEN (2026-06-21).** The full self-hosted compiler
     (lexer+parser+codegen+elf_emit + a new Linux-syscall host driver
     `fused_driver_host_main.ad`) builds as a single `x86_64-linux` host ELF via
     the Python seed and runs. Differential self-compile over the fuzz corpus
     (`.ad` host binary vs Python seed) = **300/300 = 100% behavioral match, 0
     mismatch, 0 unsupported**. No self-hosting fixpoint blocker (the `.ad`
     compiler's own source uses only the flat SoA subset both backends compile).
     Gate: `scripts/test_selfhost_cutover_dryrun.sh`. Validation:
     `fuzz_adder_diff.sh` 4 seeds×400 = 1600 progs 100%/0-miscompile,
     `fuzz_adder.sh` 600 progs 0-miscompile, `test_adder_x86_64_linux.sh` +
     `test_arm64_codegen.sh` PASS. NEXT (not done — deliberately): flip the
     default build driver to the `.ad` binary per the runbook in
     `docs/subsystems/adder-compiler.md` (config switch + CI guard via the
     dry-run + on-device fixpoint gates; Python seed retained as bootstrap +
     fallback).
4. **Userland-isolated drivers (UMDF)** — ✅ DONE (first slice: stock `.ko` in a
   restartable userland host, crash-isolated). Follow-ups: respawn supervisor, real
   BAR-backed driver, `exports.ad` parity.
5. **Kernel scaling rework** — ✅ DONE (O(active) scheduler, NTASKS→512, dynamic-CPU
   guard). Deferred perf items (per-wq locks, softirqs, slab, NUMA/RCU) stay deferred.
6. **Adder code optimizer — REFRAMED: build it IN ADDER, post-cutover.** The
   permanent home of the IR + LICM/CSE/strength-reduction/regalloc is the
   self-hosted Adder compiler (track 3), so it runs on-device and isn't written
   twice. **FREEZE the Python optimizer** at the current `-O1` peephole + `-O2`
   regalloc (Adder/-O2 ≈ 3.0× of C). Those stay ONLY as a baseline + differential
   oracle. Do NOT invest more *permanent* optimizer work in Python. The in-flight
   Python from-AST IR is a throwaway DESIGN PROTOTYPE to validate the pass shape
   where iteration is cheap; its real implementation is Adder-native. Perf goal
   (≤ ~2× of C, ideally parity) is met by the Adder-native passes.

Plus: **gate the two real boot paths in CI** — ✅ DONE (installer-image OVMF
heartbeat, non-blocking).

### Decision points (record, don't lose)

- **Python compiler = seed, Adder compiler = product.** (See redirect above.) All
  *permanent* optimization belongs in `codegen.ad` lineage, post-self-hosting-cutover.
- **LLVM — PERMANENTLY REJECTED (2026-06-21, user decision).** Not the path. We do
  NOT adopt LLVM as a second backend at any point. Perf (≤2×/parity), multi-arch
  (ARM64 already has a native backend), and any CPU mitigations are pursued
  natively in the Adder compiler / hand-rolled backends. Rationale: keep the whole
  toolchain native + self-hosted (the ethos and credibility); a giant C++ dependency
  is off the table. Don't reopen this.

---

## ⚠ Namespace law

Hamnix is **Plan 9-shaped. There is NO global filesystem route.** A
process sees a path only because something was *bound or mounted into
its own namespace*. **No work may write to a global `/var`/`/usr`/
`/etc`/`/var/lib/dpkg`/`/var/cache/apt`/`/var/www`.** All Linux-binary-
shim and distro/package state lives inside a distro-shaped namespace
exported by the userland **`distrofs`** 9P daemon; a shim is launched
`rfork(RFNAMEG)` → mount/bind `distrofs` → exec. A TODO is mis-shaped
if it says "write X to `/var/...`" without "...in the shim's distrofs
namespace" — fix the wording.

## ⚠ Boundary-discipline law

**Layer 1 (native) stays pure 9P / namespace.** The non-file modern
mechanisms — `io_uring`, `epoll`, `futex`, signalfd/eventfd/timerfd —
are the antithesis of "everything is a file." Permitted **only inside
Layer 2** as confined kernel objects for Linux guests. The moment one
becomes a native-code dependency, the architecture has been retrofitted
backwards.

---

## Kernel parity (Linux)

Full ranked gap analysis + waves: [`docs/kernel_parity_roadmap.md`](docs/kernel_parity_roadmap.md).
The Linux ABI shim (`linux_abi/`) is strong; the half-assed gaps are all
in the Layer-1 CPU-side core. Four keystones everything leans on: RCU,
the EEVDF scheduler, and the page-cache + rmap + reclaim triad.

**Wave 1 — foundations (parallel; RCU unblocks the rest)**
- [ ] **RCU core** — Tiny/Tree RCU, QS on ctx-switch + tick, `call_rcu`/
  `synchronize_rcu`. Absent today (`kernel/sched/core.ad:627`). `kernel/rcu/`.
- [ ] **EEVDF/CFS scheduler** — replace the O(NTASKS) min-vruntime linear
  scan (`kernel/sched/core.ad:1050`) with an eligibility/deadline tree.
- [ ] **rmap + struct page** — `anon_vma` + `page->mapping` (fully absent);
  prerequisite for real reclaim AND the page cache. `mm/rmap.ad` (new).

**Wave 2 — big subsystems (depend on Wave 1)**
- [ ] **VFS page cache (`address_space`)** — block-only today
  (`kernel/block/blk.ad:370`); file mmap snapshots backing (`fs/vfs.ad:6102`).
  Unified per-inode page tree + dirty tracking. `fs/` + `mm/`.
- [ ] **LRU reclaim + kswapd + watermarks** — replace the per-task O(tasks)
  walk (`mm/reclaim.ad:69`) with active/inactive LRU + background kswapd.
- [x] **softirq + workqueue pool + tasklet + threaded IRQs** — DONE. Real
  Linux-shape bottom-half stack: per-CPU softirq vectors HI..RCU with
  `raise_softirq`/`do_softirq` on IRQ-return (bounded MAX_SOFTIRQ_RESTART
  loop + ksoftirqd fallback) in `kernel/softirq.ad`; real tasklets
  (SCHED/RUN state machine, run-once-coalesced, self-serialized);
  concurrency-managed workqueue with 4 worker kthreads + `queue_work` /
  `flush_work` / `flush_workqueue` / delayed-work-via-timer in
  `kernel/workqueue.ad` (replaces the 4-slot manual-flush table);
  `request_threaded_irq` now spawns the irq thread + the top half wakes it
  on IRQ_WAKE_THREAD (`linux_abi/api_irq.ad`). Net RX migrated onto
  NET_RX_SOFTIRQ (`drivers/net/virtio_net.ad`): hard-IRQ top half ACKs +
  raises, drain runs in softirq. Proven live by `scripts/test_bh.sh`
  (in-kernel `bh_selftest_run`): all 5 assertions PASS.

**Wave 3 — scale & correctness (depend on Wave 2)**
- [x] **dcache + inode cache (+ rcu-walk)** — page/inode/dentry caches landed
  in `fs/fcache.ad`; the dentry-cache hot read path is now Linux RCU-walk:
  `fcache_dcache_lookup` runs lockless under `rcu_read_lock()` with a per-slot
  seqcount + `rcu_dereference` on the publish point, validates the live
  namespace generation + per-Pgrp key inside the stable read, and degrades to
  a locked ref-walk (`_dcache_lookup_refwalk`) on a torn read. Inserts publish
  `dc_valid` last via `rcu_assign_pointer`; evicted slots are RCU-retired and
  their byte-pool reuse is deferred past a grace period via `call_rcu`. Proven
  by the RCU-walk cases in `fcache_selftest` (`scripts/test_fcache.sh`).
- [ ] **dirty writeback throttling + per-bdi flushers** — none; `fsync` is
  a device-cache barrier only (`fs/ext4.ad:7466`). After page cache.
- [x] **per-VMA locking + maple tree** — DONE (Wave-3): VMAs now indexed by
  an augmented AVL interval tree (O(log n) find/overlap/gap; the sorted list
  stays only as the iterator), each VMA has a per-VMA spinlock, and the
  demand-fault path RCU-looks-up + trylocks the VMA with a per-mm seqcount
  fallback to the mm-wide write lock (Linux `lock_vma_under_rcu` model).
  `mm/vma.ad`; gated by `scripts/test_mm_vma_tree_logic.py` + test_mm_pressure PART E.
- [ ] **hrtimers (ns) + NO_HZ + clocksource registry** — hrtimers are
  jiffies-quantized 16-slot (`linux_abi/api_hrtimer.ad:47`), no tickless.

**Backlog (post-parity scaling / niche):** PELT + sched_domains +
SCHED_DEADLINE; RT signals + tgid thread groups; remaining 5 namespaces +
`setns`; cgroup memory/io/pids + nesting; page-allocator pcplists/zones/
migratetypes; THP/NUMA/KSM; io_uring async + net opcodes; eBPF verifier/
program-types/JIT; fair qspinlock + lockdep + kernel mutex/rwsem.

**Plan 9 law:** native control stays ctl-file-shaped; Linux-ABI parity
stays in `linux_abi/`. RCU/sched/MM/page-cache are shared Layer-1 core.

---

## Track 1 — Adder Linux target (Tier 2: compute + file I/O)

**Why:** run freestanding Adder on Linux at native speed (dev + fuzzing
+ host self-hosting). NOT for GUI/namespace apps — those need Plan 9
emulation on Linux (plan9port-scale), explicitly out of scope. This is
the unlock for tracks 2 and 3.

**Grounding:** `aarch64-linux` already exists and already emits Linux
syscall numbers — mirror it for x86. Userland is freestanding (raw
`syscall`, no glibc).

- [ ] **Register `x86_64-linux` target** beside `aarch64-linux` in
  `adder/compiler/adder.py:34` (`{codegen: x86, kbuild: False,
  bare_metal: False}`). Revisit the `bare_metal` flag — it only gates
  `.modinfo`, wrong proxy for "userspace"; consider a `userspace` flag.
- [ ] **`user/linux-runtime.S`** — Linux x86_64 syscall numbers
  (write=1, read=0, open=2, close=3, lseek=8, exit=60, …) + Linux
  `_start` (argc/argv off the stack). Mirror `user/runtime.S`.
- [ ] **`user/linux-init.lds`** — `elf64-x86-64`, `ENTRY(_start)`, drop
  the `elf32-i386`/`.code64` wrapper trick.
- [ ] **Link path** in `adder.py` (mirror `:527-571` aarch64-linux) —
  `as --64`, `ld -m elf_x86_64 -nostdlib -static`.
- [ ] **Centralize syscall numbers** (high-value cleanup) — today
  scattered as `movq $N,%rax` across `user/runtime.S`; a per-target table
  lets x86-adder-user / x86_64-linux / aarch64-* coexist without copy-paste.
- [ ] **Smoke test** — compile a file-I/O Adder program to `x86_64-linux`,
  run on host, verify read/write/exit reach the Linux kernel.

## Track 2 — Compiler fuzzer

**Why:** de-risk the solo single-pass hand backend. The May 2026 sweep
fixed 5 silent miscompiles (signed/unsigned compare, sub-8-byte pointer
writes, 2-D array addresses) — the surface is real.

- [ ] **Host-test compile target** (depends on Track 1's `x86_64-linux`).
  Reuse computational codegen; only the output/exit primitive maps to
  Linux. Generated programs run natively — millions/hr, no QEMU.
- [ ] **Program generator + predicted-output oracle.** Generator emits a
  random valid Adder program AND computes its expected result by
  construction; compiled program prints actual; compare. Catches the
  whole May bug class with no second implementation.
- [ ] **Crash/assert mode** — fuzz for compiler exceptions /
  `CodeGenError` on valid input.
- [ ] **Batched in-VM pass** for the ABI/namespace surface the host
  target can't cover (syscall numbering, `_start`, 9P semantics): boot
  Hamnix once, feed thousands of programs over a channel — don't reboot
  per program.
- [ ] **Report bug density** — this number gates the LLVM decision.
- [ ] (Later, if LLVM lands) **differential oracle** — same generated
  programs through both backends, compare.

## Track 3 — Self-hosting cutover ★ LEAD COMPILER TRACK (2026-06-21 redirect)

**Why:** close the bootstrap AND unlock the real optimizer. The build is still
Python-locked (`python3 -m compiler.adder`); `codegen.ad` is a ~2317-LOC
self-hosting SUBSET that emits raw machine bytes and drives NO build. This is now
the LEAD compiler track: the Adder-native optimizer (track 6) cannot be built until
the Adder compiler reaches parity and can host it. Progress so far: 6 real
`codegen.ad` miscompiles fixed + a host differential fuzzer (`scripts/fuzz_adder_diff.sh`,
`--ad-codegen`) added; 100% correct over 2400+ programs on the supported subset
(STATUS corrected Done→Partial).

- [ ] **Finish `compiler/codegen.ad` to FULL parity** with `codegen_x86.py` — the
  remaining feature surface that's out of the current subset: multi-dimensional
  array globals, classes/methods, for-loops, structs/member access, do-while,
  floats, `.modinfo`. Validate EVERY addition with `scripts/fuzz_adder.sh` (0
  miscompiles) + the differential mode vs the Python backend.
  - [x] **FLOATS — DONE (2026-06-21), scalar SSE float32/float64 in LOCKSTEP.**
    Implemented in BOTH `codegen_x86.py` (seed/oracle) AND `codegen.ad` plus the
    fuzzer's bit-exact oracle. FP values transit `%rax` as their IEEE bit
    pattern; SSE (`addss/subss/mulss/divss`+`sd`, `ucomi`+NaN-unordered setcc,
    `cvtsi2`/`cvtt`/`cvtss2sd`/`cvtsd2ss`, sign-bit-xor negate) runs only at the
    op site. Validated: differential gate 4 seeds × 400 = 1600 programs 100%
    accepted/correct, 0 miscompiles; Python fuzzer 1500 clean; regress pin
    unchanged. The "seed FROZEN" rule covers the OPTIMIZER ONLY (untouched);
    adding the missing FP correctness feature to the seed was required + allowed.
    See docs/subsystems/adder-compiler.md "Floating point — scalar SSE, LOCKSTEP."
  - REMAINING for cutover: by-value struct params/returns, multi-base receiver
    offset. All other constructs (multi-dim array globals, classes/methods,
    loops, structs, do-while, FLOATS) are LANDED + fuzz-proven.
- [ ] **Build the `.ad` compiler as an `x86_64-linux` host binary** (via Track 1) so
  `adder_cc` runs on the host, compiling Adder→Hamnix at native speed — Python
  becomes a one-time SEED (correct, not fast; freeze its optimizer per the redirect).
- [ ] **Cutover:** make the default build use the `.ad` compiler once it's
  fuzz-proven at parity (the Python compiler stays as the bootstrap seed only).
- [ ] **Run the `.ad` compiler in Hamnix too** (`x86_64-adder-user`) for on-device
  source packages (#186).
- [~] STATUS "on-device self-hosting Done" corrected to Partial (Track 3 pass).

## Track 4 — Userland-isolated drivers (.ko out of kernel)

**Why:** stock `.ko` modules load into kernel memory today
(`linux_abi/loader.ad`) and share the kernel fault domain — a buggy
vendor driver panics the box. A Plan 9 _and_ server-correct OS runs
drivers as restartable userland file servers.

**Scope:** ONE build. `.ko` support stays in every image (server and
desktop alike) and loads on demand based on the hardware present — no
`.ko`-free profile, no separate server build. The goal is to change
*where `.ko` executes* (a restartable userland host, not kernel space),
not whether it's available. Native drivers stay first choice where the
hardware is standardized; `.ko` remains the escape hatch for vendor-mess
HW (consumer wifi, GPUs) — now crash-isolated.

- [~] **User-mode driver framework (UMDF-style).** First vertical slice
  landed: `linux_abi/umdf_kernel.ad` exposes the three privileged
  primitives over a narrow syscall channel — MMIO map (`SYS_UMDF_MMIO_MAP`
  321, uncacheable phys→user VA), DMA alloc (`SYS_UMDF_DMA_ALLOC` 322,
  phys-contiguous + phys exposed), IRQ file (`SYS_UMDF_IRQ_OPEN` 323 +
  blocking read on the returned irq fd, per-vector WaitQueue). The driver
  posts a `#X` server (existing namespace law). Remaining: respawn
  supervisor (auto-restart on crash), real BAR-backed driver.
- [~] **Port the `.ko` loader into a userland host process.** Landed:
  `user/umdf_host.ad` runs the ET_REL load + reloc + symbol resolution +
  `init_module` dispatch in a CPL3 process; the `.ko` lands in mmap'd
  USER memory and `_printk`/MMIO/IRQ/DMA shims bottom out into the host's
  userland shim / the new syscalls. Remaining: broaden the userland shim
  table toward `linux_abi/exports.ad` parity for richer `.ko`s, and `%gs`
  per-CPU handling in userland.
- [x] **Restart/crash-isolation test** — `scripts/test_umdf_host.sh`:
  crashes a userland driver host (NULL deref), proves the kernel + hamsh
  survive, and a fresh host re-inits the `.ko` afterward. Per-task UMDF
  cleanup hook (`register_umdf_task_exit_hook`) reclaims IRQ files + DMA
  buffers on both clean exit and crash.

## Track 5 — Kernel scaling rework

**Why:** static-array ceilings calcify the longer they bake. Lift the
*structural* limits now; defer perf tuning until a workload measures it.

**Fix now (structural — gets harder over time):**
- [ ] **Dynamic CPUs** — `MAX_CPUS=16` static arrays → dynamic per-CPU
  allocation indexed by `smp_processor_id()`. Cite: `arch/x86/kernel/smp.ad`.
- [ ] **Dynamic / list-based tasks** — `NTASKS=256` is now a *static
  array of 256*; the scheduler scans all slots O(NTASKS) to pick next
  (`kernel/sched/core.ad`). Convert to intrusive per-CPU run-lists so
  pick-next is O(active), and drop the hard task ceiling.

**Defer until a contended multicore workload exists (well-trodden, not research):**
- [ ] **Per-waitqueue locks** — replace the global `wq_lock` serializing
  every WAIT↔READY transition.
- [~] **SMP work-stealing + CPU affinity** — per-CPU runqueue + load
  balancing landed (#139/#151/#397); work-stealing and affinity open.
- [ ] **Softirq / threaded IRQs** — IRQ handlers run in hard context
  today (`arch/x86/kernel/irq.ad`); add bottom-half deferral.
- [ ] **Per-CPU slab cache** — single global free list contends under
  fork storms (`mm/slab.ad`).
- [x] **Buddy merge-on-free** — DONE: `_free_pages_raw` coalesces XOR-buddies
  up to `MAX_ORDER` (canonical `__free_one_page`) under the IRQ-safe buddy
  spinlock (`mm/page_alloc.ad`). Asserting self-test
  `page_alloc_coalesce_test` + `scripts/test_buddy_coalesce.sh`.

**Deep / punt until measured:** NUMA-node awareness + per-node pools;
RCU read-side for task/VFS traversal.

- [x] **LRU-ordered reclaim + rmap + kswapd + writeback throttling** —
  Linux-shape MM parity landed: per-PFN struct-page array (`mm/page.ad`:
  flags/mapcount/LRU links/rmap word); anon reverse map (`mm/rmap.ad`) so
  reclaim finds a page's mapper without walking every task's page tables;
  active/inactive LRU with second-chance/CLOCK (`mm/lru.ad`); watermark-
  driven kswapd + direct reclaim (`mm/kswapd.ad`, low/min/high over
  memblock-headroom+buddy-free); dirty/writeback accounting +
  balance_dirty_pages throttling (`mm/writeback.ad`); LRU-tail scanner
  `reclaim_shrink_lru` evicts the coldest single-mapper anon pages via
  rmap (`mm/reclaim.ad`). OOM killer kept as the last resort. Proven by
  `scripts/test_mm_pressure.sh` PART C.

## Track 6 — Adder code optimizer (→ rough C territory)

> **★ REDIRECT (2026-06-21): the optimizer's permanent home is the ADDER compiler,
> not Python.** The Python `-O1` peephole + `-O2` regalloc below are LANDED and stay
> ONLY as a baseline + differential oracle — **the Python optimizer is FROZEN; do not
> add more permanent passes to it.** The real IR + LICM/CSE/strength-reduction/regalloc
> is built in `codegen.ad` AFTER the self-hosting cutover (Track 3, the lead track),
> so the optimizer runs on-device and isn't written twice. LLVM is **permanently
> rejected** (not the path) — the native Adder optimizer is THE route to ≤2×/parity.
> An in-flight Python from-AST IR is a THROWAWAY design prototype only.

**Why:** compiled Adder is sound but unoptimized. Baseline
(`docs/bench_adder_host.md`, `scripts/bench_adder_host.sh`): geomean
~1.6× of `gcc -O0`, ~4.3× of `-O2`, ~24× faster than CPython. The `-O2`
gap is concentrated in a few classic passes, not anything LLVM-scale.

**Goal:** rough C ballpark — **target ≤ ~2× of `-O2`** (from ~4.3×).
Non-goal: `-O2` parity / auto-vectorization.

> ### ★★★ TARGET MET (2026-07-07, orchestrator-verified on a quiet host)
> The **native Adder** optimizer (`--opt` / `ADDER_OPT=1`, 6 passes: const-fold,
> CSE, LICM, DCE, branch-fold, copy-prop) is at **geomean 1.83× of `gcc -O2`** —
> inside the ≤2× target, and *faster than* `gcc -O0` (0.56×). Optimizer ON vs OFF
> = 3.52×. Every kernel is now <2× of `-O2` except **fib (2.93×)** — irreducible
> recursive call/prologue overhead, which inlining cannot help; diminishing
> returns, left alone. Numbers: `docs/bench_opt_results.md`
> (`bash scripts/bench_opt.sh`; `rm -rf build/fuzz_ad_codegen` first).
> Measure on a QUIET host — the previously-committed 2.49× was a stale,
> under-load measurement, not a real regression.
>
> **This track is therefore on HOLD**, behind Firefox + interactive-OS QA per the
> user's sequencing. Do not open a new optimizer agent unless the user
> re-prioritizes. Default codegen (flag OFF) stays byte-identical to the seed.

The stale Python-era progression below (4.28× `-O0` → 3.47× `-O1` → 3.03× `-O2`,
geomean of `-O2`) is the **frozen Python seed's** asm-level passes, kept only as a
baseline + differential oracle. It is NOT the product optimizer.

- [x] **Increment 1 — `-O1` peephole optimizer (LANDED 2026-06-20).**
  `adder/compiler/peephole_x86.py`, gated behind `adder compile -O1` (default
  `-O0` single-pass path, used by the Hamnix image build, is unchanged).
  Four local provably-safe transforms over the emitted asm: condition→branch
  fusion, dead store-reload elim, immediate-push folding, push/pop→scratch
  forwarding (unwinds the stack-machine memory traffic via the unused
  `%r8`–`%r11`). **Result: geomean 4.24× → 3.45× of `-O2`** (1.23× speedup;
  fib 1.43×, mmul 1.38×, sieve 1.35×). 0 fuzzer miscompiles at `-O1`
  (`FUZZ_OPT=1 scripts/fuzz_adder.sh`). The IR-based steps below are the next
  increment (the peephole can't express LICM/strength-reduction/regalloc).
- [x] **Increment 2 — `-O2` stack-slot register promotion (LANDED 2026-06-21).**
  `adder/compiler/regalloc_x86.py`, gated behind `adder compile -O2` (runs
  after the `-O1` peephole; default `-O0` image-build path unchanged).
  A register allocator *over the stack slots*: the stack-machine backend keeps
  every local in an `OFF(%rbp)` slot and round-trips it through memory on every
  access; this pass promotes each function's hottest address-never-taken
  full-width scalar locals into the five callee-saved registers `%rbx,%r12–%r15`
  (never emitted by the backend, never scratched by `-O1`). Promotion is
  proven-safe per slot: only when *every* `OFF(%rbp)` appearance is a plain
  8-byte `movq` load/store (any sized/`movz*`/`movs*`/`lea`/indexed/canary use
  disqualifies it). Saves/restores via a fresh enlarged-frame slot at the
  prologue + before every `leave`. **Result: geomean 3.47× → 3.03× of `-O2`**
  (1.14× over `-O1`, 1.41× over `-O0`; sieve 2.69→2.13×, lcg 1.89→1.51×,
  collatz 5.92→5.26×, mmul 5.52→5.09×). **0 fuzzer miscompiles at `-O2`**
  (`FUZZ_OPT=2 scripts/fuzz_adder.sh`; 2000-program CI batch + 8000 soak).
  Implemented at the asm level (operates on emitted text per-function) rather
  than as a from-AST SSA IR — the same proven-safe, incremental shape as the
  `-O1` peephole, and it captures the single biggest win (memory round-trips)
  the IR was wanted for. The from-AST IR + the remaining IR-level passes below
  are still the next increment.
The three steps below were the *Python-track* plan. They were **superseded by the
2026-06-21 redirect and are now DONE natively in Adder** (`adder/compiler/{ir,cfg,opt,regalloc}.ad`,
STATUS T4/T8/T18/T18b) — the IR, LICM, CSE, DCE, copy-prop and linear-scan regalloc all
live in the self-hosted compiler and run on-device. Kept here only so the history reads
straight; do NOT implement them in Python.

- [x] ~~**Step 0 — introduce a minimal IR.**~~ Done in Adder: basic-block + value IR
  (`ir.ad`) + whole-function CFG/liveness (`cfg.ad`).
- [x] ~~**Loop-invariant code motion + strength reduction.**~~ LICM landed (`opt.ad`,
  zero-trip/trap-safe). Strength reduction not separately needed to hit the target.
- [x] ~~**CSE + simple inlining.**~~ Cross-statement CSE on extended basic blocks landed
  (with conservative aliasing-store invalidation). Inlining not needed to hit ≤2×.
- [x] **Validate:** every pass preserves results — gated on the fuzzer's `ADDER_OPT=1`
  correctness lane, flag-off objdiff byte-identity, and `scripts/bench_opt.sh`'s
  per-kernel checksum equality (a miscompiling kernel is excluded from the speed
  table, not timed). Ratio tracked in `docs/bench_opt_results.md`.

**Remaining (only if the user re-prioritizes perf):** a full IR-consuming backend
(IR coverage is ~87% of binary-op roots today; the rest still falls back to the
stack-machine emit path), and instruction-selection IR (#493+).

## CI / verification gap

- [ ] **CI must build the shipped image.** Nothing in CI runs
  `build_installer_img.sh`, so the image build sat BROKEN (`mkfs.ext4:
  Could not allocate block`) until a QA pass tripped over it —
  `HAMNIX_ROOTFS_SIZE_MB` was pinned at 512 MiB while the Debian fixture
  closure grew to 555 MiB staged. Fixed in `106b9ebb` (auto-size + a
  512 MiB floor), but the *class* of bug recurs: add a CI job that builds
  the installer image on every push. A pinned size constant that silently
  stops tracking a growing input is exactly the "regression-prone, needs a
  test" pattern.
- [ ] **Gate the two real boot paths in CI.** Today `ci.yml` gates 14
  tests, all `-kernel` multiboot (only `test_efi_gop` touches OVMF, and
  only checks pixels). Add as gates: `test_installer_boot_heartbeat.sh`
  (USB/installer image, real OVMF) and `test_installer_nvme_inram.sh`
  (installed-disk, real OVMF). Verify both finish reliably under TCG
  first; the lane the original `ci.yml` header promised never landed.

---

## Kernel hardening & correctness

- [ ] **CPU-mitigations.** SMEP landed; **SMAP CR4-flip + KASLR + KPTI**
  open. SMAP flip is gated OFF because high-half kernel pages are US=1 —
  flipping triple-faults until they're re-stamped US=0. Cite:
  `arch/x86/kernel/trap_diag.ad:382`.
- [ ] **Suspend/resume.** S3 path real; HW wake-vector trampoline in
  `entry.S` pending. S0ix later.
- [ ] **F2 thin-shim conversion.** `SYS_NICE`/`SVC_CTL`/`NETCFG`/
  `RESOLVE`/`WSYS_*` syscall arm BODIES still duplicate the ctl-file
  implementation in `arch/x86/kernel/syscall.ad`; replace with thin
  delegations.
- [~] **#439 post-exit wedge.** Boot-CR3 guard landed
  (`mm/page_alloc.ad:40-65`); a probabilistic reclaim-path
  double-free/cycle in `_try_remove_buddy` may remain — needs runtime
  verification. WIP snapshots on `worktree-agent-ae2373654138b1014`
  (`9944f32b`), `worktree-agent-a9c57d837298c09e7` (`a22bd04f`).
- [~] `stat`/`fstat` per-backend hooks — `do_stat` migrated to hook
  table (`47ab21c5`); `do_fstat` per-server migration deferred.
- [~] Delete the global `/var` tmpfs — per-Pgrp bind `/var → #t/var` in
  place; backend `vfs_mount` router entry removal needs FS-routing
  migration.
- [~] Plan 9 `note_group` + cross-task `/proc/<pid>/note` landed
  (`660978bb`); runtime verification pending.

## P9-shape hammer — long tail

- [~] **F7 #390** — FD-mark fold continuation. Pipes next (highest
  leverage).
- [ ] **F10-4 … F10-12** — remaining F10-audit findings (afd Tauth,
  `init/main.ad` split, full Dir-record atime/mtime + per-task uid, etc.).

## hamUI / DE track

- [~] **`lib/hamui.ad` MATE-class widget set** — menu/menubar,
  scrolledwindow, dialog/modal, notebook/tabs, radio, slider, spinbutton,
  combobox, progressbar, separator, image, toolbar, statusbar,
  treeview/grid, multi-line textview; grid layout + per-widget
  align/expand/fill, dynamic editing, destruction, damage tracking.
  v1 + Inc 1/2/3 landed.
- [~] **Rio-faithful reshape** — `#w` per-process bind landed; image+
  dirty-rect wire format being implemented across devwsys+hamUId+hamui.
- [ ] **DE pivot finish — substitution not addition.** Physically remove
  the dead `daemon_pixel` render fallbacks (~20K dead LOC in
  `user/hamUId.ad`); replace with a thin router. Target: `user/hamUId.ad`
  below ~10 KLOC.
- [ ] **hamsh `use hamui`** — bindings; may need hamsh closures + event
  loop + persistent state.
- [ ] X11/Xvfb bridge in a `kind=fb` layer (path to Firefox/Chromium).
- [~] BDF font store landed; runtime font-file loading deferred.
- Known bugs: cursor hotspot (clicks at arrow bottom, not tip); terminal
  ~0.5s input lag.

## GPU / graphics (#181–185, native-first)

Target: glxgears + vkcube spinning in a hamUI window, accelerated where
present. **Laws:** (1) DE never requires the Linux *namespace* — baseline
is native Vulkan + native software rasterizer (NOT lavapipe). (2) `.ko`
modules via the L-shim ARE used (`i915.ko`); `.ko` ≠ namespace.

- [~] **#181 Phase 0** — native Vulkan spine + software rasterizer + WSI.
- [~] **#182 Phase 1** — native virtio-gpu + native venus in a VM.
- [~] **#183 Phase 2** — DE composites via native spine; Linux X11 apps
  bridge in via venus-shaped ICD + Zink (optional).
- [ ] **#184 Phase 3 (METAL)** — Intel i915 silicon via `i915.ko`.
- [ ] **#185 Phase 4 (optional)** — native ANV-equivalent.

## Driver / storage / input maturity

- [ ] AHCI NCQ (serialises on slot 0); hot-plug / COMRESET retry;
  multi-port naming (`sd1`…).
- [ ] NVMe multi-queue + multi-namespace.
- [ ] Partition: extended-CHS, BSD disklabel, APM; GPT UTF-16 names;
  `mount /dev/sd0p1 /mnt` path-to-slot resolver.
- [ ] ext4 mkfs multi-block-group layout + journal at mkfs time; ext4
  truncate on index-node files; growing a full dir block (prior attempt
  `bc1cb9c8` reverted `bb7ba653` — broke heartbeat boot).
- [~] Networking forwarding-path auto-wiring (gated behind
  `ip_forwarding_enabled`, default 0).
- [ ] Input: dead-key / compose / IME; blocking read on `/dev/mouse`;
  MADT IRQ-override consumption.
- [ ] stock-Linux `.ko` coverage: `MAX_EXPORTS` bumps; `usbcore`+
  `xhci_hcd`, `libphy`, `8021q`, `nf_conntrack` core. (Reconcile with
  Track 4 — `.ko` work should target the userland host, not the kernel.)

## Userspace polish

- [ ] `enter linux { /bin/sh }` interactive stdin doesn't reach the Linux
  process (sshd sessions have their own pty).
- [ ] Nested `` `{ } `` command substitution clobbers (hamsh).
- [ ] busybox `ls` enumeration XFAIL (musl DIR-fd round-trip); busybox
  `sh -c "a|b"` internal-pipeline `#GP`.
- [ ] `/bin` tool audit for cwd-relative defaults.
- [ ] CPython: trim frozen stdlib; PGO/LTO; C extensions once a U-track
  `ld.so` exists.
- [ ] TEMP_DEBUG cleanup pass when bring-up stabilises.

## Metal bring-up (human-in-the-loop)

- [ ] **xHCI v1 metal** — HCH-clear MMIO poll wedges on real Intel NUC;
  USB mouse dead on metal.
- [ ] Asus i5-4210U boot crash; built-in keyboard never responded under
  Legacy/BIOS (hypothesis EHCI-routed).
- [ ] MMIO-stall class audit: ehci, ahci, nvme.
- [ ] Real NIC silicon: e1000e EEPROM on Intel; r8169 RX on RTL8168;
  Broadcom tg3; Intel igb; NUC I219 silent.
- [ ] Drop the FAT12 32 MiB ESP cap via GPT-ESP path.
- [ ] **#117/#118** — verify >4GB fix kills real-HW #UD + persisted logs
  (USB boot at `-m 8G`).

## Bigger lifts — no immediate plan

- [ ] iwlwifi / ath11k / mt76 — real radios. Firmware via the planned
  `non-free-firmware` channel.
- [ ] Browser in a hamUI window — gated on hamUI Phase 5 (X11 bridge).
- [~] Multi-arch ARM64 (#175) — aarch64 backend landed; full bare-metal
  kernel port (Phase 3+) open. **Note:** an LLVM second backend (see
  Decision points) would subsume much of this.
- [ ] **Arch convergence** — factor an arch-interface; link a shared
  portable core into ARM64. Do once ARM64 bring-up is stable.
- [ ] Signed package indexes (sha256 covers tarballs; index unsigned).
