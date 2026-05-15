# kernel/sched/core.py
#
# Mirrors kernel/sched/core.c in Linux at minimal scale: a small
# runqueue, task_struct, and schedule() built on the context-switch
# primitive in arch/x86/kernel/sched_asm.S.
#
# **Preemption model (M16.9+):** schedule() is called ONLY from the
# timer ISR. There is no cooperative yield_cpu — every task switch
# happens through common_irq, so every paused task's stack has the
# same shape: iret frame at top, common_irq's saved-register slots
# below, then __switch_to_asm's 6 callee-saved regs and a return
# address.
#
# Freshly-created tasks don't yet have a previous IRQ stack to
# resume on, so kthread_create() pre-builds an equivalent one
# byte-by-byte and points the return-from-__switch_to_asm slot at
# kthread_bootstrap (which IS common_irq's tail).
#
# The first task is entered via enter_first_task() in
# arch/x86/kernel/sched_asm.S — it loads the new task's stack
# pointer and never returns to the boot context.

from mm.memblock import memblock_alloc
from kernel.printk.printk import printk0, printk1

extern def __switch_to_asm(prev: Ptr[uint8], next: Ptr[uint8])
extern def enter_first_task(task: Ptr[uint8])
extern def kthread_bootstrap()


# task_struct — leading fields match Linux's struct order so a debug
# dump on either side reads the same way. Field offset matters only
# for `sp`, which __switch_to_asm references at offset 0.
class TaskStruct:
    sp:         uint64       # offset  0: saved %rsp on context switch
    pid:        uint64       # offset  8: logical id
    stack_base: uint64       # offset 16: bottom of this task's stack
    stack_size: uint64       # offset 24: bytes allocated for stack
    name0:      uint64       # offset 32: 8 ASCII chars, little-endian
    state:      uint64       # offset 40: TASK_RUNNING / etc. (unused)


KSTACK_SIZE: uint64 = 16384

# Boot-GDT segment selectors (matches arch/x86/boot/header.S gdt64).
KERNEL_CS: uint64 = 0x08
KERNEL_DS: uint64 = 0x10
# RFLAGS for a fresh kernel task: bit 1 reserved-must-be-1, bit 9 IF=1.
INITIAL_RFLAGS: uint64 = 0x202

# Runqueue — for now exactly two worker tasks. Round-robin: 0 → 1 → 0.
# No "idle" slot: when the system has nothing else to do, both tasks
# can busy-hlt and the timer just bounces between them. SMP and a
# proper idle task land later.
NTASKS:      uint64 = 2
task_table:  Array[2, TaskStruct]
next_pid:    uint64 = 1
current_idx: uint64 = 0


def kthread_create(slot: uint64, entry: uint64, name0: uint64):
    # Build a freshly-created task whose first __switch_to into it
    # looks identical to resuming a previously-preempted task. The
    # stack-from-the-top layout (high → low addresses) is:
    #
    #     iret frame: SS, RSP, RFLAGS, CS, RIP        [5 quads]
    #     vec, error_code                             [2 quads]
    #     9 caller-saved regs (zeroed)                [9 quads]
    #     return-addr = kthread_bootstrap             [1 quad]
    #     6 callee-saved regs (zeroed)                [6 quads]  <- task->sp
    #
    # After __switch_to_asm pops the 6 callee-saved regs and rets,
    # control lands in kthread_bootstrap, which pops the 9 caller-
    # saved (zeros are fine for a never-before-run task), drops the
    # fake vec+ec, and iretq's into `entry` with IF=1.
    stack: uint64 = memblock_alloc(KSTACK_SIZE, 16)
    if stack == 0:
        printk0("kthread_create: OOM, halting\n")
        asm_volatile("cli")
        while True:
            asm_volatile("hlt")

    stack_top: uint64 = stack + KSTACK_SIZE
    sp: uint64 = stack_top

    # ----- iret frame (CPU pops in reverse: RIP first, SS last) ----
    sp = sp - 8
    cast[Ptr[uint64]](sp)[0] = KERNEL_DS           # SS
    sp = sp - 8
    cast[Ptr[uint64]](sp)[0] = stack_top           # RSP (target ESP)
    sp = sp - 8
    cast[Ptr[uint64]](sp)[0] = INITIAL_RFLAGS      # RFLAGS = IF | rsvd
    sp = sp - 8
    cast[Ptr[uint64]](sp)[0] = KERNEL_CS           # CS
    sp = sp - 8
    cast[Ptr[uint64]](sp)[0] = entry               # RIP = entry fn

    # ----- vec + error_code (matches trap_stub's two pushes) ------
    sp = sp - 8
    cast[Ptr[uint64]](sp)[0] = 0                   # error_code
    sp = sp - 8
    cast[Ptr[uint64]](sp)[0] = 0                   # vector

    # ----- 9 caller-saved regs (order matches common_irq pushes) --
    i: uint64 = 0
    while i < 9:
        sp = sp - 8
        cast[Ptr[uint64]](sp)[0] = 0
        i = i + 1

    # ----- return address: __switch_to_asm `ret` lands here -------
    sp = sp - 8
    cast[Ptr[uint64]](sp)[0] = cast[uint64](&kthread_bootstrap)

    # ----- 6 callee-saved regs (__switch_to_asm pops these) -------
    i = 0
    while i < 6:
        sp = sp - 8
        cast[Ptr[uint64]](sp)[0] = 0
        i = i + 1

    task_table[slot].sp         = sp
    task_table[slot].pid        = next_pid
    task_table[slot].stack_base = stack
    task_table[slot].stack_size = KSTACK_SIZE
    task_table[slot].name0      = name0
    task_table[slot].state      = 0

    next_pid = next_pid + 1


def sched_init():
    # No global state to set up other than the pid counter — the
    # task_table itself is zeroed by the BSS pass at boot.
    next_pid    = 1
    current_idx = 0


def schedule():
    # Called from timer_interrupt() in arch/x86/kernel/time.py.
    # Round-robin between the worker slots. Replace with a proper
    # rq->cfs when fairness becomes a concern.
    #
    # No-op when there are no kernel tasks to switch to — this covers
    # the M16.17 / M16.19 path where start_kernel drops directly into
    # a userspace task without registering kernel threads. The timer
    # ISR still fires (bumping jiffies, etc.); schedule() just bails
    # because the next slot's sp == 0 and there's nothing to load.
    prev: uint64 = current_idx
    nxt:  uint64 = current_idx + 1
    if nxt >= NTASKS:
        nxt = 0
    if task_table[nxt].sp == 0:
        return
    current_idx = nxt
    __switch_to_asm(cast[Ptr[uint8]](&task_table[prev]),
                    cast[Ptr[uint8]](&task_table[nxt]))


def get_current_pid() -> uint64:
    return task_table[current_idx].pid


def start_first_task():
    # One-shot bootstrap: dive into task 0. Never returns.
    enter_first_task(cast[Ptr[uint8]](&task_table[0]))
