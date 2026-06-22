# Hamnix Kernel vs Linux — Parity Gap Analysis & Roadmap

**Authoritative ranked roadmap for the kernel-parity endgame.**
Date: 2026-06-21. Anchor commit: ~71012d0f. Scope: native kernel core
(`kernel/`, `mm/`, `fs/`, `arch/x86/`, `sys/src/9/`, `drivers/`) and the
Linux ABI shim (`linux_abi/`). Goal: REAL Linux parity — no half-assed
/ lite / stub subsystems left standing.

## Ground rules (Plan 9 ethos)

- **Native control stays ctl-file-shaped.** Process/resource control is
  `echo ... > /proc/PID/ctl` and per-process namespaces (Pgrp), NOT new
  Linux syscalls. Do not add Linux syscalls to the native Layer-1 path.
- **Linux-ABI parity lives in `linux_abi/`** (Layer 2). A Linux program
  must see honest semantics or an honest `-ENOSYS`, never undefined
  behaviour.
- **The CPU-side core (scheduler, MM, locking, time) is Layer 1** and is
  shared by both worlds — that is where the deepest "lite" gaps are, and
  where parity work has the biggest blast radius.

## Verdict legend

- **REAL** — genuine implementation, comparable in shape to Linux (may be
  smaller in scale, e.g. fixed table sizes, but architecturally honest).
- **LITE** — works for the demo/common case but architecturally short of
  Linux (fixed array where Linux uses a tree; jiffies where Linux uses
  ns; synchronous where Linux is async; single-level where Linux nests).
- **STUB** — API surface present, body is a no-op / returns NULL / token.
- **ABSENT** — not implemented at all.

---

## Ranked roadmap table

Ranked by parity-impact × correctness-risk (highest first). "Size" is a
rough order of magnitude of the lift, not a time budget.

| # | Subsystem | Current state (evidence) | Verdict | Delta to Linux parity | Size | Risk / blast radius | Disjoint agent scope |
|---|-----------|--------------------------|---------|-----------------------|------|---------------------|----------------------|
| 1 | **RCU** | **DONE** — real quiescent-state-based RCU landed in `kernel/rcu/rcu.ad` (flat per-CPU QS bitmask GP engine). `rcu_read_lock`/`rcu_read_unlock` (per-CPU + per-task nesting, preempt-safe), `call_rcu`/`synchronize_rcu`/`rcu_barrier`, `rcu_assign_pointer`/`rcu_dereference`. QS sources: context switch (`rcu_note_context_switch`) + idle extended-QS (`rcu_idle_enter`/`exit`). Applied to the global task list: `task_lookup_by_pid` is RCU-read-side; `task_reap` defers slot reuse via `call_rcu` (`_task_slot_rcu_free`) so a lock-free reader never sees a recycled slot. Gated boot self-test `rcu_selftest` + `scripts/test_rcu.sh`. Design: `docs/rcu_design.md`. | DONE | — | — | — | Done. Hooks live in `kernel/sched/core.ad` (one-line `rcu_note_context_switch` on the real-switch path; idle QS in both idle loops). `arch/x86/kernel/time.ad` tick QS optional follow-up (GP already advances via ctx-switch + idle + the `rcu_advance_gp` pump). |
| 2 | **Scheduler: CFS-lite → EEVDF/CFS** | `kernel/sched/core.ad`: weighted vruntime + `prio_to_weight[40]` (`:1520`), but `_pick_next` is an **O(NTASKS) linear scan** for min-vruntime (`:1050`), fixed `task_table:[512]` (`:1031`). No rbtree/maple, no EEVDF lag/eligibility/deadline, no `min_vruntime` tree invariant. | LITE | Replace the linear scan with a real per-rq timeline (rbtree or augmented tree) keyed by virtual deadline; implement EEVDF eligibility + lag, request-size slices. This is the headline CPU-fairness gap. | L | High — hot path on every tick/wakeup; correctness of fairness + latency. Self-contained to sched core though. | `kernel/sched/` core + a new `kernel/sched/fair.ad`. |
| 3 | **MM: page reclaim + LRU + kswapd + rmap** | `mm/reclaim.ad:69` walks **live tasks directly**, per-task 256-page cap (`:66`); no active/inactive LRU, no `kswapd` kthread, no watermarks, no refault. **rmap is fully ABSENT** (no `anon_vma`, no `page->mapping`). | LITE→ABSENT | Build `struct page` flags + rmap (anon_vma chains, file `address_space` rmap), active/inactive LRU lists, a `kswapd` kthread per node, watermark-driven + direct reclaim, shrinker framework, refault/workingset. rmap is the prerequisite. | XL | High — under memory pressure the current O(tasks) walk is both unscalable and cannot migrate/age pages. Touches page_alloc, vma, slab, fs page cache. | `mm/` (`reclaim.ad`, new `rmap.ad`, `page.ad`), kswapd kthread via `linux_abi/api_kthread.ad` native side. |
| 4 | **VFS: page cache (address_space)** | **ABSENT.** Block-level buffer cache only: 512-entry sector cache `kernel/block/blk.ad:370`. File-backed mmap **snapshots backing at open** (`fs/vfs.ad:6102` `vfs_pread_backing`), no per-inode page tree, no dirty tracking. `fs/ext4.ad:7469` explicit TODO: "a real page cache, delayed allocation." | ABSENT | Add a unified per-inode `address_space` (xarray/radix of cached pages), wire mmap + read/write through it, dirty-page tracking, writeback. This is THE filesystem-parity keystone and is tightly coupled to #3 (LRU/reclaim of page-cache pages) and #5 (writeback). | XL | Very high — changes how all file I/O and file mmap work; coherency with the existing block buffer cache; interacts with reclaim. | `fs/` + `mm/` (page cache straddles both); coordinate with #3. |
| 5 | **MM: dirty writeback throttling + per-bdi flushers** | ABSENT. Writeback only on explicit `msync`/`munmap` (`mm/vma.ad:675`). `fsync` is a device-cache barrier (`fs/ext4.ad:7466`). No `balance_dirty_pages`, no dirty ratios, no flusher threads, no dirty-inode tracking. | ABSENT | `balance_dirty_pages` throttling, dirty/background ratios, per-bdi writeback kthreads, dirty-inode lists. Depends on #4 (needs a page cache to have dirty pages). | L | Medium-high — without it a write-heavy load can OOM; gated behind #4. | `mm/` + `fs/` writeback; after #4. |
| 6 | **VFS: dcache + inode cache** | **DONE.** Real hashed page/inode/dentry caches in `fs/fcache.ad`: page cache (address_space), `(server,ino)` inode cache with LRU, and a hashed `(Pgrp,path)` dentry cache with negative dentries, LRU, and O(1) generation invalidation, wired into `resolve_path` (`fs/vfs.ad:4678`). The dentry hot read path is **RCU-walk** (Linux `__d_lookup_rcu` analogue): `fcache_dcache_lookup` runs lockless under `rcu_read_lock()` with a per-slot **seqcount** + `rcu_dereference` on the publish point, validates the live namespace generation + per-Pgrp key inside the seqcount-stable read, and degrades to a locked **ref-walk** (`_dcache_lookup_refwalk`) on a torn read. Inserts publish `dc_valid` last via `rcu_assign_pointer`; evicted slots are RCU-retired and their byte-pool reuse deferred past a grace period via `call_rcu`. | DONE | — | L | — | `fs/fcache.ad` (built on #1 RCU); `scripts/test_fcache.sh`. |
| 7 | **Deferred work: softirq + tasklet + workqueue** | **softirq ABSENT** — deferred work is timer-tick polling + direct calls (`api_e1000e.ad:763` "skip the softirq pipeline"). **tasklet STUB** (`api_mac80211.ad:840`). **workqueue LITE** — 4-slot table, **manual flush, no worker pool** (`linux_abi/api_kthread.ad:232`). NAPI called directly from MSI handler, no budget. | ABSENT/LITE | A real softirq layer (`raise_softirq`/`do_softirq`, per-CPU pending mask, ksoftirqd), tasklet queues, a `system_wq` with per-CPU `kworker` pools, NAPI budget/poll scheduling, threaded IRQs that actually spawn (`api_irq.ad:439` records thread_fn but never spawns). | **DONE** | High — net RX, timers, driver bottom-halves all depend on it; latency + throughput. Couples to #1 (RCU-bh) and kthread infra. | DONE: `kernel/softirq.ad` (per-CPU softirq vectors HI..RCU, `raise_softirq`/`do_softirq` on IRQ-return w/ bounded loop + ksoftirqd; real tasklets w/ SCHED/RUN state machine), `kernel/workqueue.ad` (4 worker kthreads, `queue_work`/`flush_work`/`flush_workqueue`/delayed-work-via-timer — replaces the 4-slot table), `linux_abi/api_irq.ad` (`request_threaded_irq` spawns the irq thread, top half wakes it on IRQ_WAKE_THREAD). Net RX migrated onto NET_RX_SOFTIRQ in `drivers/net/virtio_net.ad`. Proven by `scripts/test_bh.sh`. NAPI budget still TODO (RX drain is unbudgeted, same as before). |
| 8 | **MM: per-VMA locking + maple/interval tree** | ✅ DONE (Wave-3). VMAs are now indexed by an **augmented AVL interval tree** keyed on `[start,end)` with a `subtree_max_end` augmentation — O(log n) `find_vma` / overlap / mmap-gap search (the sorted list is retained only as the in-order iterator). Each VMA has a **per-VMA spinlock**; the demand-fault path RCU-looks-up the VMA in the tree, trylocks just that VMA (a fault on VMA A no longer serializes against a fault on VMA B), and confirms a per-mm **seqcount** to detect a racing split/remove, falling back to the mm-wide write lock — Linux's `lock_vma_under_rcu`→`mmap_read_lock` model. COW fork / demand-fault / mmap / munmap-split / mremap / rmap / MAP_SHARED writeback all preserved. | DONE | Implemented in `mm/vma.ad` (`_vt_*` AVL, `_vma_tree_*`, `vma_lock_fault_vma`/`vma_unlock_vma`, `vma_mm_write_lock`/seqcount). Verified by `scripts/test_mm_vma_tree_logic.py` (pure-logic gate) + PART E of `scripts/test_mm_pressure.sh` (in-kernel boot gate). | L | DONE | `mm/vma.ad` (+ `mm/reclaim.ad` test wiring). |
| 9 | **Locking: RCU-lists/seqlocks/qspinlock/lockdep** | Spinlocks are **naive test-and-set** (`arch/x86/kernel/spinlock_asm.S:33`) — unfair, starves under contention (no ticket/qspinlock). Seqlocks **vDSO-only** (`arch/x86/kernel/vdso_image.S:52`), kernel data uses spinlocks. No lockdep, no llist/lockref/RCU-lists. No kernel mutex/rwsem (Plan 9 sems + futex only). | LITE | Fair qspinlock, kernel-side seqlocks for timekeeping/stats, lockdep validator, lockless primitives (llist/lockref), and real sleeping `mutex`/`rwsem` with priority inheritance. Most want #1. | L | Medium — fairness + deadlock detection; per-primitive, can land incrementally. | `arch/x86/kernel/spinlock_asm.S` + new `kernel/locking/`. |
| 10 | **Time: hrtimers + NO_HZ + clocksource registry + POSIX CPU timers** | hrtimers are **LITE jiffies-resolution** (16-slot table, 10ms granularity, `linux_abi/api_hrtimer.ad:47`) — NOT ns-precision, no rbtree. timer wheel is a 16-slot flat table (`api_timer.ad:48`), no cascade. **NO_HZ ABSENT** (constant HZ=100; AP-idle uses directed reschedule IPI — correct but not tickless). clocksource has TSC/PIT/HPET but **no generic registry** (`drivers/clocksource/hpet.ad:34`). **POSIX CPU timers ABSENT**. | LITE/ABSENT | ns-resolution hrtimer rbtree per base, a real timer-wheel cascade, generic clocksource/clockevent registry with rating + switching, NO_HZ_IDLE dynticks, POSIX per-process/thread CPU timers. | L | Medium — latency of timers + idle power; mostly self-contained in arch time + linux_abi timers. | `arch/x86/kernel/time.ad` + `linux_abi/api_hrtimer.ad`/`api_timer.ad`. |
| 11 | **Scheduler: PELT load tracking + sched_domains + load balancing** | No PELT (`util_avg`/`load_avg`/`runnable_avg` absent). Load balancing is **work-steal only** (`_sched_try_pull_locked`, trylock-and-backoff `:1126`), no `sched_domains`, no periodic balancer, no NUMA topology. RT/deadline: SCHED_FIFO/RR REAL (`:1494`), **SCHED_DEADLINE ABSENT**. | LITE/ABSENT | PELT signals feeding placement, sched_domain hierarchy + periodic `load_balance`, SCHED_DEADLINE (EDF/CBS) class. Builds on #2. | L | Medium — multi-CPU utilisation + RT correctness; after #2. | `kernel/sched/` (after #2). |
| 12 | **Signals: realtime signals + siginfo + thread groups** | Signals 1–22 REAL (`kernel/sched/core.ad:7185`), masks/sigaction/sigprocmask REAL. **RT signals (SIGRTMIN–MAX) ABSENT**, no `sigqueue`/`siginfo_t` to handler (SA_SIGINFO unwired), **thread groups (tgid) STUB** — `tgkill` treats as `kill(tid)` (`u_syscalls.ad:8898`), `gettid`==pid. Plan 9 notes (`sysnote.ad`) are the native equivalent and are REAL. | LITE | RT signal queue with siginfo, SA_SIGINFO handler frame, real thread-group (tgid) semantics + process-group signal delivery. | M | Medium — needed for correct glibc/pthread + job control; in `linux_abi/` + core signal fields. | `linux_abi/u_syscalls.ad` + `kernel/sched/core.ad` signal fields. |
| 13 | **Namespaces: pid/net/uts/ipc/user + setns** | Only **mount ns REAL** via Plan 9 Pgrp (`sysproc.ad:167`). pid/net/uts/ipc/user **ABSENT** — rejected `-EINVAL` (`u_syscalls.ad:1165–1172`). **`setns` ABSENT**. cgroup ns ABSENT. | ABSENT | Map the remaining 5 Linux ns types onto the Pgrp spine (pid-ns virtualises pid view; uts/ipc are small; net-ns is large; user-ns is security-deep) + `setns`/`unshare` coverage. Respect Plan 9 framing — these are bindings, not global views. | L (net/user) / M (pid/uts/ipc) | Medium-high — container credibility; pid-ns and net-ns each substantial; user-ns is security-sensitive. | `sys/src/9/port/sysproc.ad` + `linux_abi/`. |
| 14 | **cgroup v2: memory/io/pids controllers + nesting** | Only **cpu.max REAL** (`kernel/sched/cgroup_cpu.ad`), **flat single-level** (8 slots, no nesting). memory/io/pids/cpuset controllers ABSENT, no `cgroup.subtree_control`, no v1. | LITE | memory controller (couples to #3 memcg charge/reclaim), io.max, pids.max, real nested hierarchy + `subtree_control`. | L | Medium — resource isolation; memory controller gated behind #3. | `kernel/sched/cgroup_cpu.ad` → `kernel/cgroup/` + `mm/` for memcg. |
| 15 | **MM: page allocator hardening (pcplists/migratetypes/zones)** | Real buddy (`mm/page_alloc.ad:87`, MAX_ORDER=10) but **no per-CPU pageset/pcplists** (every alloc takes global lock + list), **no migrate types**, **no zones** (DMA/Normal/Highmem), no `struct page` refcounts (links live in page data). | LITE | per-CPU pcplists fast path, migrate-type isolation (anti-fragmentation), zone structure + watermarks, real `struct page` array with refcounts. | M-L | Medium — alloc scalability + fragmentation; zones interact with reclaim watermarks (#3). | `mm/page_alloc.ad` + `mm/page.ad` (new). |
| 16 | **THP / hugetlb / NUMA / KSM** | hugetlb 2MiB demand-paged LITE (`mm/vma.ad:124`), **no khugepaged/THP collapse**, **NUMA ABSENT** (single node), **KSM ABSENT**. NUMA mempolicy syscalls exist in `linux_abi/u_mempolicy.ad` but no underlying nodes. | LITE/ABSENT | khugepaged + transparent collapse, NUMA nodes/zones/migration/autonuma, KSM dedup daemon. Largely post-parity scaling; lowest near-term priority. | L each | Low near-term — only matters at large scale / specific workloads. | `mm/` (defer until 1–8 land). |
| 17 | **io_uring depth** | REAL synchronous, **16 opcodes** (`linux_abi/u_iouring.ad:90`), real SQ/CQ rings + registered buffers + linked SQEs. **No SQPOLL/IOPOLL, no async completion, no net opcodes (send/recv/connect)**. | LITE | Async completion engine (needs workqueue #7), SQPOLL, network opcodes, more of the modern opcode set. | M | Low-medium — already honest; depth grows after #7. | `linux_abi/u_iouring.ad` (after #7). |
| 18 | **eBPF depth** | REAL interpreter + **LITE verifier** (`linux_abi/u_bpf.ad`). 2 map types (HASH/ARRAY), no program types (kprobe/XDP/cgroup), no helpers, no tail calls, no ringbuf, no JIT. | LITE | Typed program types + attach points, helper functions, ringbuf/perf maps, a real data-flow verifier, optional JIT. | L | Low — niche; honest today. | `linux_abi/u_bpf.ad` (defer). |

**Already REAL (no parity action needed, for the record):** IDT/LAPIC/IOAPIC/MSI-X
interrupt dispatch (`arch/x86/kernel/irq.ad`, `apic.ad`); jiffies/HZ tick + TSC
ns timekeeping + vDSO; SCHED_FIFO/RR (`core.ad:1494`); per-CPU runqueue locks
(`rq_locks[16]`, `core.ad:1140`); ptrace basics (`u_ptrace.ad`); clone/threads +
wait4/zombie reaping; SysV IPC + POSIX MQ + pipes + Unix sockets/SCM_RIGHTS +
overlayfs (all REAL in `linux_abi/`/`fs/`); kthread lifecycle; buffer cache
(`kernel/block/blk.ad:370`); ~248/450 syscalls wired (55%). Atomics/barriers
(LOCK cmpxchg/xadd, SFENCE/MFENCE) REAL.

---

## Top-10 biggest parity wins (dispatch as waves)

Ordered for the orchestrator. Each wave is internally disjoint so its
agents can run in parallel; later waves depend on earlier foundations.

**Wave 1 — foundations (mostly parallel; RCU unblocks the rest)**
1. **RCU core** (#1) — Tiny/Tree RCU + QS reporting on ctx-switch & tick.
   Keystone; unblocks lockless dcache, RCU-bh, safe deferred free.
2. **EEVDF/CFS scheduler timeline** (#2) — replace the O(N) min-vruntime
   scan with an eligibility/deadline tree. Disjoint from #1 (sched core).
3. **rmap + struct page** (#3a) — anon_vma + page->mapping. Prerequisite
   for real reclaim AND the page cache. Disjoint from #1/#2 (mm).

**Wave 2 — the big subsystems (depend on Wave 1)**
4. **VFS page cache (address_space)** (#4) — unified per-inode page tree;
   wire mmap + read/write through it. Couples to #3a.
5. **LRU reclaim + kswapd + watermarks** (#3b) — real aging + background
   reclaim on top of rmap (#3a) and page cache (#4).
6. **softirq + workqueue + tasklet + threaded IRQs** (#7) — real bottom
   halves + kworker pools; uses RCU-bh (#1).

**Wave 3 — scale & correctness (depend on Wave 2)**
7. **dcache + inode cache (+ rcu-walk)** (#6) — kill the no-op stubs;
   rcu-walk on RCU (#1).
8. **dirty writeback throttling + per-bdi flushers** (#5) — on page
   cache (#4).
9. ~~**per-VMA locking + maple tree** (#8)~~ — ✅ DONE (Wave-3): augmented AVL interval tree (O(log n)) + per-VMA spinlock + RCU-lookup/seqcount fault model in `vma.ad`.
10. **hrtimers ns-resolution + NO_HZ + clocksource registry** (#10) —
    real high-res timers + tickless idle.

**Backlog (post-parity scaling / niche):** PELT + sched_domains +
SCHED_DEADLINE (#11); RT signals + tgid (#12); remaining namespaces +
setns (#13); cgroup memory/io/pids + nesting (#14); page-allocator
pcplists/zones/migratetypes (#15); THP/NUMA/KSM (#16); io_uring async +
net opcodes (#17); eBPF verifier/program-types/JIT (#18); fair qspinlock
+ lockdep + kernel mutex/rwsem (#9).

## Honest bottom line

The **Linux ABI shim (`linux_abi/`) is genuinely strong** — IPC, io_uring,
sockets, overlayfs, ptrace, ~55% syscall coverage are all REAL, not stubs.
The **gaps are in the Layer-1 CPU-side core**: there is **no RCU**, the
scheduler pick is an **O(N) scan** (no EEVDF tree), there is **no page
cache** (block-only), **no rmap**, **no real reclaim/kswapd**, **no
softirq/workqueue pool**, **dcache/inode caches are no-op stubs**, and
**hrtimers are jiffies-quantized**. These are the half-assed subsystems to
eliminate. RCU (#1), the EEVDF scheduler (#2), and the page-cache+rmap+
reclaim triad (#3/#4) are the four keystones that everything else leans on.
