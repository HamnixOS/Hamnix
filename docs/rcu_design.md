# RCU (Read-Copy-Update) — Hamnix design

Status: **landed**. Files: `kernel/rcu/rcu.ad`, `kernel/rcu/rcu_selftest.ad`,
QS + reclaim hooks in `kernel/sched/core.ad`, init in `init/main.ad`, test
`scripts/test_rcu.sh`.

RCU lets readers run lock-free while updaters defer reclamation until every
read-side critical section that was in flight when they began has completed.
This was the #1 kernel-parity hole (`docs/kernel_parity_roadmap.md` row 1).

## The contract (matches Linux)

* A **reader** brackets a critical section with `rcu_read_lock()` /
  `rcu_read_unlock()`. A pointer published with `rcu_assign_pointer()` and read
  with `rcu_dereference()` is guaranteed fully-initialised, and the object it
  refers to is not reclaimed until the reader leaves the section.
* An **updater** unlinks an object, then either `call_rcu(head, func)` to defer
  `func(head)` past the next grace period, or `synchronize_rcu()` to block until
  a grace period elapses. `rcu_barrier()` drains outstanding callbacks at
  teardown.
* A **grace period (GP)** waits for ALL readers that started before it began to
  finish. After a GP no reader can still hold a pre-GP pointer ⇒ reclaim is safe.

## Grace-period engine — flat per-CPU QS bitmask

Hamnix runs ≤ `MAX_CPUS` (16) logical CPUs, so a single 64-bit bitmask covers
every CPU and a flat scan is cheap (no RCU tree needed — correctness over
cleverness).

* `rcu_gp_seq` — GP sequence counter. Even = idle, odd = GP in progress.
  Completed-GP count = `rcu_gp_seq >> 1`.
* `rcu_gp_need_qs` — bitmask of CPUs that still owe a quiescent state (QS) for
  the in-flight GP. The GP completes (odd→even) when this reaches 0.
* `rcu_cpu_idle_mask` — CPUs in the idle/HLT extended quiescent state. A GP
  never waits on an idle CPU (it cannot be inside a reader and has no context
  switches to drive a QS while halted). Cleared on wake.

A GP starts (`_rcu_start_gp_locked`) by snapshotting `online & ~idle` into
`need_qs`. Each CPU clears its own bit at a QS. When the mask empties the GP
closes and ready callbacks run.

### Quiescent-state (QS) sources

1. **Context switch** — `rcu_note_context_switch()` on the scheduler's real
   `prev != next` switch path (`kernel/sched/core.ad schedule()`), gated on the
   outgoing task's read nesting being 0. This is the ONLY scheduler hook RCU
   adds (plus the idle-QS calls and the per-task nesting save/restore).
2. **Idle** — `rcu_idle_enter()` before HLT in both idle loops (BSP idle inside
   `schedule()`, AP idle loop), `rcu_idle_exit()` on wake.
3. **The pump** — `rcu_advance_gp()` (callable from a timer tick or a blocking
   wait) reports this CPU's QS and harvests idle CPUs, so a uniprocessor (or a
   box where peers are parked) still makes progress.

## Read side and preemption

`rcu_read_lock`/`unlock` bump a per-CPU nesting counter (`rcu_cpu_read_nesting`)
under a brief IRQ mask. The QS report refuses while nesting != 0, so a CPU is
never counted quiescent mid-reader.

For the scheduler agent's CONFIG_PREEMPT-shape work, the per-CPU nesting is
**saved into the outgoing task's `task_struct.rcu_read_nesting` and restored from
the incoming task** across every context switch (`rcu_save_read_nesting` /
`rcu_restore_read_nesting`). A task preempted mid-`rcu_read_lock` therefore
carries its nesting with it, and whatever CPU it lands on is correctly held
non-quiescent until it unlocks. On the non-preempt BSP path the save/restore is
a no-op (depth 0 in, 0 out).

## Memory ordering

x86 has a strong memory model (no store→store or load→load reorder for the
producer/consumer pattern RCU needs). `rcu_assign_pointer` publishes via an
`atomic_cas64` (LOCK CMPXCHG = an ordered, compiler+CPU fence) so earlier
initialising stores are visible before the pointer; `rcu_dereference` is the
address-dependent acquire load. The named accessors localise the one place a
future weaker arch would add explicit barriers.

## Callback path

`call_rcu(head, func)` does not allocate: callbacks live in a static pool
(`RCU_CB_POOL` = 1024 slots), threaded as a per-CPU singly-linked list. Each
callback is tagged with the completed-GP count it must outlast; it runs once
`(rcu_gp_seq >> 1)` advances past the tag. `_rcu_invoke_ready_callbacks_locked`
detaches a node, frees its pool slot, then invokes `func(head)` through a
first-class `Fn[None, uint64]` pointer (so a callback may itself `call_rcu`).
Pool exhaustion falls back to a synchronous `synchronize_rcu` drain.

`synchronize_rcu()` forces a fresh GP (so it cannot piggy-back on a GP that
predates this call's readers), then pumps + yields until the target completed-GP
count is reached. `rcu_barrier()` pumps until no callbacks remain anywhere.

## Proof of use: the global task list

The task list (`task_table[]`, used by /proc, kill, wait, ps) is the hot
read path RCU is applied to:

* **Readers** — `task_lookup_by_pid()` (the canonical pid→slot resolver every
  /proc / kill / waitpid / note-delivery path funnels through) now runs its
  hash probe + linear-scan fallback inside `rcu_read_lock`/`rcu_read_unlock`.
* **Reclaim** — `task_reap()` no longer publishes a dead slot `STATE_FREE` +
  pushes it onto the freelist inline. It drops the pid mapping + run-list link,
  then `call_rcu`s `_task_slot_rcu_free` (via an embedded `rcu_head` in the
  task_struct). The slot sits in post-reap limbo (not FREE, not on the freelist
  ⇒ neither `_find_free_slot` nor the O(1) freelist can hand it out) until a
  grace period elapses. Only then does the callback flip it FREE + enqueue it
  for reuse. A concurrent lock-free reader therefore can never observe a slot
  recycled (torn pid/state) under it — the classic use-after-free RCU prevents.

## Self-test (`rcu_selftest`, gated boot:37.rcu / `scripts/test_rcu.sh`)

Pure in-RAM, no disk, passes on TCG. Asserts:

* **T1** a `call_rcu` callback is deferred while a reader holds
  `rcu_read_lock` even across an attempted GP, and runs after unlock + a GP;
* **T2** `synchronize_rcu` advances the completed-GP count (a real GP elapsed);
* **T3** `rcu_barrier` drains outstanding callbacks;
* **T4** the task-list RCU traversal is correct under an add /
  RCU-deferred-remove stress loop — live pids resolve, removed slots are NOT
  published FREE before their grace period, removed pids stop resolving, and
  after a GP every removed slot is RCU-freed.

T4 uses inert test-only slots (`rcu_st_claim_task` / `rcu_st_reap_task`) that
drive the exact add / RCU-deferred-remove pattern of the real reap without its
heavyweight memory reclaim (which assumes alloc_pages-backed stacks).

## Follow-ups (not blocking)

* A timer-tick QS (`arch/x86/kernel/time.ad`) is optional — GPs already advance
  via context-switch + idle + the `rcu_advance_gp` pump.
* RCU-walk dcache (roadmap #6) and RCU-bh for softirqs (#7) can now build on
  this engine.
