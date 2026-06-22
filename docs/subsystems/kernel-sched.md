# Kernel Core & Scheduler

> **Source of truth:** `init/main.ad`, `kernel/sched/core.ad`,
> `kernel/sched/loadavg.ad`, `kernel/core/coredump.ad`, `kernel/panic.ad`,
> `kernel/list.ad`, `kernel/stack_protect.ad`, `kernel/printk/`,
> `kernel/vt/vt.ad`, `arch/x86/kernel/sched_asm.S`,
> `arch/x86/kernel/time.ad`
> **Last verified against source:** 2026-06-10

## Purpose

Layer-0 of Hamnix: the bring-up sequence, the task model, and the
preemptive scheduler. Internally this layer is deliberately **Linux-shape**
(`task_struct`, a runqueue, a tick) — the "unit of work" is porting a
Linux `kernel/sched/core.c` idiom into `kernel/sched/core.ad`. The
Plan-9 shape lives one layer up (`sys/src/9/port/`).

## Key files

| Path | Role |
|--|--|
| `init/main.ad` | `start_kernel()` — the boot sequence, mirrors Linux `init/main.c` |
| `kernel/sched/core.ad` | `TaskStruct`, the runqueue, `schedule()`, CFS-lite weights, RT policy, rlimits, OOM-adj, affinity |
| `kernel/sched/loadavg.ad` | 1/5/15-minute load-average accounting |
| `kernel/core/coredump.ad` | ELF process core dumps + fatal-signal table |
| `kernel/panic.ad` | `WARN_ON`, panic |
| `kernel/list.ad` | `ListHead` intrusive doubly-linked list (Linux `list.h` shape) |
| `kernel/stack_protect.ad` | stack-canary support |
| `kernel/printk/printk.ad` | kernel log ring + `pr_info`/`pr_warn`/`pr_err` |
| `kernel/printk/esp_log.ad` | persist kernel log to a `LOG.TXT` extent on the ESP (serial-less HW debug) |
| `kernel/printk/printk_log.ad` | log buffer backing |
| `kernel/vt/vt.ad` | virtual terminal core (VT1..VT4) |
| `arch/x86/kernel/sched_asm.S` | `__switch_to_asm` raw register/rsp context switch |
| `arch/x86/kernel/time.ad` | PIT @ 100 Hz tick, TSC calibration, jiffies |

## Architecture & data structures

**`TaskStruct`** (`kernel/sched/core.ad:156`) is the per-task control
block. The asm context switch depends on its field offsets, so the
layout is offset-annotated and append-only. Notable fields:

- `sp` (offset 0) — saved `%rsp`; `__switch_to_asm` finds it here.
- `pid`, `parent_pid`, `state` (`STATE_*`), `is_user` (CPL3 flag).
- A 16-slot **per-task file-descriptor table**: `fd_idx`, `fd_pos`,
  `fd_buf`, `fd_buflen` (offsets 64..512). This is how VFS and the
  Plan-9 layer hang open files off a task.
- `cr3` (offset 512) — per-task PML4 physical address. Every task gets
  its own top-level page table cloned from the BSP's; lower levels are
  shared (kernel-half sharing, Linux-style).
- `cwd` (128 bytes) — per-task working directory, inherited at spawn.
- `is_linux_userspace` (offset 672) — per-task syscall ABI selector:
  0 = native Hamnix numbering, 1 = Linux x86_64 numbering forwarded to
  the Linux ABI dispatch. The Linux-ELF loader flips this before the
  child's first `iretq`. (See [linux-abi.md](linux-abi.md).)
- `vfork_done`, plus a per-task FS_BASE for glibc TLS (`arch_prctl`).

The scheduler is a **CFS-lite** weighted-fair scheduler: nice values map
to weights (`sched_weight_for_nice`, `_sched_fill_weight_table`), a
`min_vruntime` baseline, and per-task quanta (`sched_quantum_for`). It
also supports **realtime policies** (`sched_set_scheduler`,
`sched_priority_max/min`, `sched_is_realtime`), **rlimits**
(`rlimit_get_cur/max/set`), **OOM-adjust** (`oom_adj_*`), and **CPU
affinity** (`sched_get_affinity`).

SMP: each CPU owns a **per-CPU runqueue** (mirrors Linux's per-CPU
`struct rq`), locked via `_rq_lock_cpu(cpu)`/`_rq_unlock_cpu` with
`_sched_irq_push/pop` for IRQ-safe sections; tasks home to a CPU and
new work is placed by `sched_pick_target_cpu`. Wait queues use
`_wq_lock_irq`. Idle APs HLT and are woken by a reschedule IPI
(tickless), not a PAUSE/MWAIT spin.

## Entry points

- `start_kernel()` (`init/main.ad`) — the boot sequence. Order (per the
  file header, mirrors Linux): `setup_early_printk` →
  `trap_init`/`idt_init` → `mem_init` → `setup_per_cpu_areas` →
  `i8259_init` + `time_init` → `sched_init` + `kthread_create` →
  `local_irq_enable` → `start_first_task` (never returns).
- `sched_init()` (`core.ad:2274`) — build the runqueue, seed the idle/init tasks.
- `start_first_task(first_slot)` (`core.ad:3745`) — jump into the first task; never returns.
- `schedule()` (`core.ad:2990`) — the core reschedule; the timer ISR is the primary caller.
- `sched_make_ready(slot)` / `sched_make_ready_on(slot, cpu)` — wake/enqueue a task.
- `sched_pick_target_cpu(slot)` — SMP placement.
- `sched_set_nice` / `sched_get_nice`, `sched_set_scheduler`,
  `sched_get_affinity` — policy/priority knobs (driven by the Linux ABI
  and by `/proc/<pid>/ctl`).

## Invariants & gotchas

- **`TaskStruct.sp` must stay at offset 0** — `sched_asm.S` hardcodes it.
  New fields are appended at the end (see the `is_linux_userspace`
  comment) so earlier offsets never shift.
- After `start_first_task`, the system is fully preemptive: the only
  routine that calls `schedule()` is the timer path. Do not assume
  cooperative yields.
- SMP runqueue is single-locked. A documented prior bug (see
  `memory/`/STATUS) was the steal-window race where `schedule()` dropped
  the rq lock and marked `prev` READY before `__switch_to_asm` saved
  `prev->sp`; an AP could steal a not-yet-saved task. Touch the
  lock/READY/save ordering with care.
- The tick is 100 Hz LAPIC-periodic by default (`arch/x86/kernel/time.ad`),
  but the **Linux-shape time subsystem** (`kernel/time/`) now sits on top
  of it: a **clocksource registry** (TSC/HPET/jiffies, rating-based
  selection, mult/shift cyc→ns), a **clockevent** LAPIC one-shot, a real
  **ns-resolution hrtimer queue** (sorted by absolute ns expiry, backed by
  the clockevent one-shot — replaces the old 16-slot jiffies wheel), and
  **NO_HZ dynticks** that stop the periodic tick when a CPU idles with no
  near deadline (skipped jiffies accounted on wake). A self-rearming
  scheduler-tick hrtimer keeps preemption alive in one-shot mode. POSIX
  per-process CPU timers (`CLOCK_PROCESS_CPUTIME_ID`) ride the same base.
  Brought up at `boot:16.time` (`tick_init`); self-test
  `scripts/test_hrtimer.sh`. Resolution before→after: 10 ms (jiffies wheel)
  → sub-ms (TSC clocksource + clockevent one-shot).

## Related docs

- [memory.md](memory.md) — allocators the scheduler/task setup depends on.
- [arch-x86.md](arch-x86.md) — IDT/IRQ/timer/context-switch asm.
- [plan9-namespace.md](plan9-namespace.md) — `rfork`/`exec`/namespaces that drive task creation.
- [../architecture.md](../architecture.md) — the layered model.
