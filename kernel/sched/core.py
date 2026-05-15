# kernel/sched/core.py
#
# Mirrors kernel/sched/core.c in Linux at the smallest meaningful
# granularity: a task_struct, a tiny "runqueue" (two slots, no
# fairness, no priority), and schedule()/yield() built on a single
# context-switch primitive __switch_to_asm in arch/x86/kernel/sched_asm.S.
#
# Pre-emption isn't here yet — schedule() is only called from explicit
# yield() points. Once the timer-tick path lands, the timer ISR will
# tail-call schedule() to take CPU time away from a long-running task.

from mm.memblock import memblock_alloc
from drivers.tty.serial.early_8250 import early_puts, early_print_hex64

extern def __switch_to_asm(prev: Ptr[uint8], next: Ptr[uint8])

# task_struct layout — mirrors the leading fields of Linux's
# `struct task_struct`. We expose only what M16.6 needs; field order
# matters because __switch_to_asm reads `sp` at offset 0.
class TaskStruct:
    sp:         uint64       # offset  0: saved %rsp on context switch
    pid:        uint64       # offset  8: logical id (just a counter)
    stack_base: uint64       # offset 16: bottom of this task's stack
    name0:      uint64       # offset 24: ASCII name (first 8 bytes)


KSTACK_SIZE: uint64 = 16384      # 16 KiB per kernel thread

# "Runqueue" — for M16.6 we reserve exactly 3 slots:
#   [0] init (whatever called sched_init / schedule first; usually
#       start_kernel itself), saved into here lazily on first switch
#   [1..2] kernel threads created via kthread_create
# Round-robin walks 0 → 1 → 2 → 0. Replace with a proper struct rq +
# list_head once we have list primitives wired.
NTASKS:      uint64 = 3
task_table:  Array[3, TaskStruct]
next_pid:    uint64 = 1
current_idx: uint64 = 0


def init_task_stack(stack_base: uint64, entry: uint64) -> uint64:
    # Pre-build the callee-saved register frame __switch_to_asm pops
    # on the first dispatch. After 6 pops + ret, %rip = entry. Layout
    # at the top of the new stack (high address → low address):
    #   [ entry ][ rbp=0 ][ rbx=0 ][ r12=0 ][ r13=0 ][ r14=0 ][ r15=0 ]
    # We return the stack pointer that points at r15 (i.e. the value
    # __switch_to_asm should load into %rsp).
    sp: uint64 = stack_base + KSTACK_SIZE
    sp = sp - 8
    cast[Ptr[uint64]](sp)[0] = entry         # return address
    sp = sp - 8
    cast[Ptr[uint64]](sp)[0] = 0             # rbp
    sp = sp - 8
    cast[Ptr[uint64]](sp)[0] = 0             # rbx
    sp = sp - 8
    cast[Ptr[uint64]](sp)[0] = 0             # r12
    sp = sp - 8
    cast[Ptr[uint64]](sp)[0] = 0             # r13
    sp = sp - 8
    cast[Ptr[uint64]](sp)[0] = 0             # r14
    sp = sp - 8
    cast[Ptr[uint64]](sp)[0] = 0             # r15
    return sp


def kthread_create(slot: uint64, entry: uint64, name0: uint64):
    # Allocate stack from memblock, fill the task_struct, prebuild the
    # initial context frame. `slot` is an index into task_table; for
    # M16.6 the caller picks 0 or 1 directly. Linux returns a
    # task_struct* from kthread_create(); we return through table
    # mutation since Pynux's struct-pointer ergonomics are still thin.
    stack: uint64 = memblock_alloc(KSTACK_SIZE, 16)
    if stack == 0:
        early_puts("kthread_create: OOM\n")
        asm_volatile("cli")
        while True:
            asm_volatile("hlt")
    sp: uint64 = init_task_stack(stack, entry)

    task_table[slot].sp         = sp
    task_table[slot].pid        = next_pid
    task_table[slot].stack_base = stack
    task_table[slot].name0      = name0

    next_pid = next_pid + 1


def sched_init():
    # The currently-executing context (start_kernel) becomes "task 0".
    # Its sp / pid / stack are filled in lazily on the first
    # schedule() switch: __switch_to_asm will write task0.sp when we
    # leave the start_kernel context for the first time.
    task_table[0].pid        = 1
    task_table[0].stack_base = 0    # bootstrap stack from header.S
    task_table[0].name0      = 0x5f74696e69       # "init_"  (LE)
    # task_table[0].sp set on first __switch_to_asm
    next_pid = 2
    current_idx = 0


def schedule():
    # Round-robin among slots 0..NTASKS-1. Slot 0 is the init context
    # (start_kernel) which usually has no real work between yields;
    # workers live in 1..NTASKS-1.
    prev: uint64 = current_idx
    nxt:  uint64 = current_idx + 1
    if nxt >= NTASKS:
        nxt = 0
    current_idx = nxt
    __switch_to_asm(cast[Ptr[uint8]](&task_table[prev]),
                    cast[Ptr[uint8]](&task_table[nxt]))


def yield_cpu():
    # Cooperative yield. Linux spells this `cond_resched()` /
    # `schedule()`; the simpler-name variant maps to user-mode
    # `sched_yield(2)` rather than the kernel-side cond_resched, but
    # for our purposes the semantics are identical: drop the CPU and
    # let the scheduler pick something.
    schedule()
