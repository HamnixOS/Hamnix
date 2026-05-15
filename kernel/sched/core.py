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


class TaskStruct:
    sp:           uint64       # offset  0: saved %rsp on context switch
    pid:          uint64       # offset  8: logical id
    kstack_base:  uint64       # offset 16: bottom of this task's kstack
    kstack_top:   uint64       # offset 24: top (high addr); fed to TSS.RSP0
    ustack_base:  uint64       # offset 32: bottom of user stack (0 for kernel)
    state:        uint64       # offset 40: STATE_*
    is_user:      uint64       # offset 48: 1 if CPL=3 task
    name0:        uint64       # offset 56: 8-char ASCII tag (debug)


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
    enter_first_task(cast[Ptr[uint8]](&task_table[0]))


# --- helpers for syscall layer -------------------------------------

def current_task_pid() -> uint64:
    return task_table[current_idx].pid


def current_task_is_user() -> uint64:
    return task_table[current_idx].is_user
