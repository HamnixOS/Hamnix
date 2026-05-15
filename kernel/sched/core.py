# kernel/sched/core.py
#
# Mirrors kernel/sched/core.c in Linux. Owns task_struct definitions,
# the runqueue, and the schedule() / context-switch path that the
# timer ISR drives. As of M16.20 the runqueue holds up to 4 tasks
# (kernel and user mixed), each with its own kernel stack; user
# tasks additionally have a user stack and their initial kernel-stack
# image is pre-built to land in CPL=3 via iretq.
#
# Task states (mirrors the relevant subset of TASK_RUNNING / TASK_DEAD):
#
#   STATE_FREE     0  - slot is unused; create_*_task may claim it
#   STATE_READY    1  - on the runqueue; eligible for schedule()
#   STATE_RUNNING  2  - currently on a CPU (only one slot at a time
#                       on uniprocessor)
#   STATE_EXITED   3  - finished; never scheduled again. Stacks stay
#                       allocated (no reclaim yet); slot is left in
#                       state EXITED so schedule() skips it.
#
# Preemption is timer-driven (M16.9): schedule() is called from
# timer_interrupt(). We also call it explicitly from SYS_EXIT to give
# the CPU to a sibling when the current task tears down.

from mm.memblock import memblock_alloc
from mm.page_alloc import alloc_page
from kernel.printk.printk import printk0, printk1

extern def __switch_to_asm(prev: Ptr[uint8], next: Ptr[uint8])
extern def enter_first_task(task: Ptr[uint8])
extern def kthread_bootstrap()
extern def tss_set_rsp0(rsp0: uint64)
extern def local_irq_disable()
extern def get_bsp_cr3() -> uint64
extern def load_cr3(value: uint64)
extern def memcpy(dst: Ptr[uint8], src: Ptr[uint8], n: uint64) -> Ptr[uint8]


class TaskStruct:
    sp:           uint64       # offset  0: saved %rsp on context switch
    pid:          uint64       # offset  8: logical id
    kstack_base:  uint64       # offset 16: bottom of this task's kstack
    kstack_top:   uint64       # offset 24: top (high addr); fed to TSS.RSP0
    ustack_base:  uint64       # offset 32: bottom of user stack (0 for kernel)
    state:        uint64       # offset 40: STATE_*
    is_user:      uint64       # offset 48: 1 if CPL=3 task
    name0:        uint64       # offset 56: 8-char ASCII tag (debug)
    # Per-task file descriptor table — 4 slots. Each fd has a file
    # index (or special marker for stdin/stdout/stderr) and a
    # 64-bit read/write position. We keep the two side-by-side
    # rather than packed so callers don't have to pun bit-fields out.
    fd_idx:       Array[4, uint32]    # offset 64..80
    fd_pos:       Array[4, uint64]    # offset 80..112
    # Task-specific PML4 physical address. For M16.28 every task
    # gets its own top-level page table page, freshly cloned from
    # BSP's so the lower-level mappings (PDPT/PD) are shared — same
    # kernel-half sharing scheme Linux uses, just without separate
    # user-half mappings yet.
    cr3:          uint64              # offset 112


# State constants (mirror Linux's task->state space at a tiny scope).
STATE_FREE:    uint64 = 0
STATE_READY:   uint64 = 1
STATE_RUNNING: uint64 = 2
STATE_EXITED:  uint64 = 3

KSTACK_SIZE: uint64 = 4096
USTACK_SIZE: uint64 = 4096

# Boot-GDT selectors (matches arch/x86/boot/header.S).
KERNEL_CS:  uint64 = 0x08
USER_CS_R3: uint64 = 0x23                # 0x20 | RPL=3
USER_DS_R3: uint64 = 0x1B                # 0x18 | RPL=3
RFLAGS_INITIAL: uint64 = 0x202           # bit 1 reserved | bit 9 IF=1

# Runqueue + bookkeeping.
NTASKS:      uint64 = 4
task_table:  Array[4, TaskStruct]
next_pid:    uint64 = 1
current_idx: uint64 = 0                  # index into task_table


# --- internal: stack-image builder shared by kernel and user paths --

def _build_initial_kstack(kstack_top: uint64, iret_cs: uint64,
                          iret_ss: uint64, iret_rsp: uint64,
                          iret_rip: uint64) -> uint64:
    # Plant the same layout every task ends up with after one round
    # of preemption: iret frame + vec/ec + 9 caller-saved + ret to
    # kthread_bootstrap + 6 callee-saved. After __switch_to_asm
    # pops the 6 and rets, control lands in kthread_bootstrap which
    # iretq's into iret_rip with iret_cs / iret_rsp / iret_ss /
    # RFLAGS = RFLAGS_INITIAL.
    sp: uint64 = kstack_top

    sp = sp - 8
    cast[Ptr[uint64]](sp)[0] = iret_ss
    sp = sp - 8
    cast[Ptr[uint64]](sp)[0] = iret_rsp
    sp = sp - 8
    cast[Ptr[uint64]](sp)[0] = RFLAGS_INITIAL
    sp = sp - 8
    cast[Ptr[uint64]](sp)[0] = iret_cs
    sp = sp - 8
    cast[Ptr[uint64]](sp)[0] = iret_rip

    # fake error code + vector pushed by trap_stub
    sp = sp - 8
    cast[Ptr[uint64]](sp)[0] = 0
    sp = sp - 8
    cast[Ptr[uint64]](sp)[0] = 0

    # 9 caller-saved (r11/r10/r9/r8/rdi/rsi/rdx/rcx/rax), all zero
    i: uint64 = 0
    while i < 9:
        sp = sp - 8
        cast[Ptr[uint64]](sp)[0] = 0
        i = i + 1

    # return-address from __switch_to_asm: lands in kthread_bootstrap
    sp = sp - 8
    cast[Ptr[uint64]](sp)[0] = cast[uint64](&kthread_bootstrap)

    # 6 callee-saved (r15..rbp), all zero
    i = 0
    while i < 6:
        sp = sp - 8
        cast[Ptr[uint64]](sp)[0] = 0
        i = i + 1

    return sp


# --- public: slot management ---------------------------------------

def _find_free_slot() -> int32:
    i: uint64 = 0
    while i < NTASKS:
        if task_table[i].state == STATE_FREE:
            return cast[int32](i)
        i = i + 1
    return -1


def sched_init():
    next_pid    = 1
    current_idx = 0
    # All slots already zero by .bss init -> state = STATE_FREE.


# --- public: task construction ------------------------------------

def kthread_create(entry: uint64, name0: uint64) -> int32:
    # Create a CPL=0 kernel thread. Returns the new task's slot index,
    # or -1 on OOM. The first __switch_to into the new task pops 6
    # zeroed callee-saved, rets to kthread_bootstrap, iretq's into
    # `entry` with CS = kernel CS, SS = kernel DS, RFLAGS = 0x202.
    slot: int32 = _find_free_slot()
    if slot < 0:
        printk0("kthread_create: no free task slot\n")
        return -1
    kstack: uint64 = memblock_alloc(KSTACK_SIZE, 16)
    if kstack == 0:
        return -1
    kstack_top: uint64 = kstack + KSTACK_SIZE

    sp: uint64 = _build_initial_kstack(
        kstack_top, KERNEL_CS, 0x10, kstack_top, entry,
    )

    s: uint64 = cast[uint64](slot)
    task_table[s].sp          = sp
    task_table[s].pid         = next_pid
    task_table[s].kstack_base = kstack
    task_table[s].kstack_top  = kstack_top
    task_table[s].ustack_base = 0
    task_table[s].state       = STATE_READY
    task_table[s].is_user     = 0
    task_table[s].name0       = name0
    # Kernel threads share the BSP's page table (no per-task mappings
    # for them yet — and they don't need user pages anyway).
    task_table[s].cr3         = get_bsp_cr3()
    _init_fd_table(s)
    next_pid = next_pid + 1
    return slot


def create_user_task(entry: uint64, name0: uint64) -> int32:
    # Allocate kstack + ustack, build a freshly-preempted-looking
    # stack image whose iret frame returns to CPL=3 at `entry`.
    slot: int32 = _find_free_slot()
    if slot < 0:
        printk0("create_user_task: no free task slot\n")
        return -1

    kstack: uint64 = alloc_page()
    ustack: uint64 = alloc_page()
    if kstack == 0 or ustack == 0:
        return -1
    kstack_top: uint64 = kstack + KSTACK_SIZE
    ustack_top: uint64 = ustack + USTACK_SIZE

    sp: uint64 = _build_initial_kstack(
        kstack_top, USER_CS_R3, USER_DS_R3, ustack_top, entry,
    )

    s: uint64 = cast[uint64](slot)
    task_table[s].sp          = sp
    task_table[s].pid         = next_pid
    task_table[s].kstack_base = kstack
    task_table[s].kstack_top  = kstack_top
    task_table[s].ustack_base = ustack
    task_table[s].state       = STATE_READY
    task_table[s].is_user     = 1
    task_table[s].name0       = name0
    # Per-task PML4: clone the BSP's so the kernel half is mapped
    # identically (lower-level PDPT/PD tables are shared). When we
    # add user-only private mappings, they live inside this PML4
    # without affecting the kernel or other tasks.
    new_pml4: uint64 = alloc_page()
    if new_pml4 == 0:
        return -1
    memcpy(cast[Ptr[uint8]](new_pml4),
           cast[Ptr[uint8]](get_bsp_cr3()), 4096)
    task_table[s].cr3 = new_pml4
    _init_fd_table(s)
    next_pid = next_pid + 1
    return slot


# --- public: schedule / lifecycle ---------------------------------

def _pick_next() -> int32:
    # Round-robin starting at current_idx + 1. Returns -1 if no slot
    # is in STATE_READY OR STATE_RUNNING (i.e. nobody to run).
    n: uint64 = NTASKS
    i: uint64 = current_idx + 1
    tried: uint64 = 0
    while tried < n:
        if i >= n:
            i = 0
        st: uint64 = task_table[i].state
        if st == STATE_READY or st == STATE_RUNNING:
            return cast[int32](i)
        i = i + 1
        tried = tried + 1
    return -1


def schedule():
    # Called from timer_interrupt() (preemption) and from
    # task_exit_current() (cooperative drop). Round-robins the
    # runqueue; updates TSS.RSP0 to the new task's kstack so a
    # subsequent CPL-3 IRQ lands there; then __switch_to.
    nxt_signed: int32 = _pick_next()
    if nxt_signed < 0:
        # Nobody to run. If even the current task is no longer ready,
        # there are no live tasks at all; halt the box.
        if task_table[current_idx].state != STATE_RUNNING and \
           task_table[current_idx].state != STATE_READY:
            printk0("schedule: no live tasks; halting\n")
            local_irq_disable()
            while True:
                asm_volatile("hlt")
        return

    nxt: uint64 = cast[uint64](nxt_signed)
    if nxt == current_idx:
        return  # only one ready task

    prev: uint64 = current_idx
    if task_table[prev].state == STATE_RUNNING:
        task_table[prev].state = STATE_READY
    task_table[nxt].state = STATE_RUNNING
    current_idx = nxt

    # Update RSP0 BEFORE the swap so a stray CPL-3 IRQ that happens
    # between this point and the next sysret/iretq still lands on
    # the right stack.
    tss_set_rsp0(task_table[nxt].kstack_top)

    # Switch page tables if the incoming task uses a different PML4.
    # Skipping the write when CR3 wouldn't change avoids a needless
    # TLB flush — Linux does the same fast-path in __switch_mm.
    if task_table[nxt].cr3 != task_table[prev].cr3:
        load_cr3(task_table[nxt].cr3)

    __switch_to_asm(cast[Ptr[uint8]](&task_table[prev]),
                    cast[Ptr[uint8]](&task_table[nxt]))


def task_exit_current():
    # Mark the current task EXITED and yield. Stacks intentionally
    # NOT freed (no reclaim path yet — that's a slab + RCU follow-up).
    task_table[current_idx].state = STATE_EXITED
    printk1("task: pid %d exited\n", task_table[current_idx].pid)
    schedule()
    # schedule() never returns when we're EXITED — it halts if there
    # are no other ready tasks, or switches us out forever.


def start_first_task():
    # Bootstrap: dive into task slot 0. Never returns. Caller is
    # responsible for ensuring slot 0 has been populated (kthread_create
    # or create_user_task returns slot 0 on the first call after
    # sched_init() because state was STATE_FREE).
    task_table[0].state = STATE_RUNNING
    current_idx = 0
    tss_set_rsp0(task_table[0].kstack_top)
    # Load the first task's page table — its PML4 has the same
    # mappings as BSP's but the address is different. CR3 must point
    # at the task's PML4 before its iretq-to-user runs, or else any
    # subsequent CR3 change in schedule() would TLB-flush relative
    # to the wrong root.
    if task_table[0].cr3 != 0:
        load_cr3(task_table[0].cr3)
    enter_first_task(cast[Ptr[uint8]](&task_table[0]))


# --- helpers for syscall layer -------------------------------------

# Special fd_idx markers. Anything < these values is a real initramfs
# file index; the markers reserve the high quarter of the uint32 space.
FD_CLOSED_MARK: uint32 = 0xFFFFFFFF
FD_STDIN_MARK:  uint32 = 0xFFFFFFFC
FD_STDOUT_MARK: uint32 = 0xFFFFFFFE
FD_STDERR_MARK: uint32 = 0xFFFFFFFD


def current_task_pid() -> uint64:
    return task_table[current_idx].pid


def current_task_is_user() -> uint64:
    return task_table[current_idx].is_user


def current_task() -> Ptr[TaskStruct]:
    return &task_table[current_idx]


def task_pml4(slot: int32) -> uint64:
    # Caller-side accessor — saves init/main.py from poking
    # task_table directly across the module boundary.
    return task_table[cast[uint64](slot)].cr3


def _init_fd_table(slot: uint64):
    # Pre-open stdin / stdout / stderr; the rest start CLOSED. Linux's
    # exec() does the same thing — the launched binary inherits the
    # parent's standard streams or gets them freshly attached.
    task_table[slot].fd_idx[0] = FD_STDIN_MARK
    task_table[slot].fd_idx[1] = FD_STDOUT_MARK
    task_table[slot].fd_idx[2] = FD_STDERR_MARK
    task_table[slot].fd_idx[3] = FD_CLOSED_MARK
    task_table[slot].fd_pos[0] = 0
    task_table[slot].fd_pos[1] = 0
    task_table[slot].fd_pos[2] = 0
    task_table[slot].fd_pos[3] = 0
