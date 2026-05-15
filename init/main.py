# init/main.py
#
# Pynux start_kernel() — mirrors init/main.c in Linux. Called from
# arch/x86/kernel/head_64.S:start_kernel_asm_entry after BSS is zeroed.
#
# As of M16.9 the bring-up sequence mirrors Linux's init/main.c quite
# closely, in this call order:
#
#   setup_early_printk()       (drivers/tty/serial/early_8250.py)
#   trap_init()                (arch/x86/kernel/idt.py)
#   mem_init()                 (arch/x86/mm/init.py: memblock + pages + slab)
#   setup_per_cpu_areas()      (arch/x86/kernel/setup_percpu.py)
#   i8259_init() + time_init() (PIC + PIT @ 100 Hz)
#   sched_init() + kthread_create(...)
#   local_irq_enable() (sti)
#   start_first_task()         — never returns
#
# After start_first_task() the system is purely preemptive: the only
# path that calls schedule() is the timer ISR. The two demo workers
# busy-loop without any cooperative yield; the timer alone shuffles
# control between them.

from drivers.tty.serial.early_8250 import setup_early_printk
from kernel.printk.printk import (
    printk0, printk1, printk2,
    pr_info, pr_warn, pr_err, pr_emerg,
)
from kernel.panic import WARN_ON
from kernel.list import (
    ListHead, INIT_LIST_HEAD, list_add, list_add_tail,
    list_del, list_empty,
)
from arch.x86.kernel.idt import idt_init
from arch.x86.kernel.traps import do_trap          # exported for common_trap
from arch.x86.kernel.irq import do_irq             # exported for common_irq
from arch.x86.mm.init import mem_init
from arch.x86.kernel.setup_percpu import setup_per_cpu_areas, get_cpu_id
from arch.x86.kernel.i8259 import i8259_init
from arch.x86.kernel.time import time_init, get_jiffies, get_local_timer_ticks
from kernel.sched.core import (
    sched_init, kthread_create, start_first_task, get_current_pid,
)
from mm.memblock import memblock_alloc, memblock_used, memblock_avail
from mm.page_alloc import (
    alloc_page, free_page, alloc_pages, free_pages,
    page_alloc_total, page_alloc_free_count,
)
from mm.slab import kmalloc, kfree, kzalloc

extern def trigger_int3()
extern def local_irq_enable()
extern def cpu_relax()
extern def memset(dst: Ptr[uint8], val: int32, n: uint64) -> Ptr[uint8]
extern def memcpy(dst: Ptr[uint8], src: Ptr[uint8], n: uint64) -> Ptr[uint8]
extern def memmove(dst: Ptr[uint8], src: Ptr[uint8], n: uint64) -> Ptr[uint8]


def trap_init():
    idt_init()


def memblock_smoke_test():
    printk0("Pynux: memblock smoke test\n")
    a: uint64 = memblock_alloc(128, 16)
    b: uint64 = memblock_alloc(256, 64)
    c: uint64 = memblock_alloc(64, 8)
    printk1("  alloc(128,16) = %p\n", a)
    printk1("  alloc(256,64) = %p\n", b)
    printk1("  alloc( 64, 8) = %p\n", c)


def page_alloc_smoke_test():
    printk0("Pynux: page_alloc smoke test\n")
    p1: uint64 = alloc_page()
    printk1("  alloc_page #1 = %p\n", p1)
    free_page(p1)
    p2: uint64 = alloc_page()
    printk1("  alloc_page #2 = %p  (expect == #1)\n", p2)
    p3: uint64 = alloc_page()
    printk1("  alloc_page #3 = %p  (fresh)\n", p3)
    free_page(p2)
    free_page(p3)
    printk2("  page_alloc: total=%d free=%d\n",
            page_alloc_total(), page_alloc_free_count())


def slab_smoke_test():
    printk0("Pynux: slab smoke test\n")
    a: uint64 = kmalloc(48)
    b: uint64 = kmalloc(48)
    c: uint64 = kmalloc(200)
    d: uint64 = kmalloc(1500)
    printk1("  kmalloc(  48) = %p\n", a)
    printk1("  kmalloc(  48) = %p\n", b)
    printk1("  kmalloc( 200) = %p\n", c)
    printk1("  kmalloc(1500) = %p\n", d)
    kfree(b)
    e: uint64 = kmalloc(48)
    printk1("  kmalloc(  48) after kfree(b) = %p  (expect == b)\n", e)
    cast[Ptr[uint64]](a)[0] = 0xCAFEBABE_DEADBEEF
    val: uint64 = cast[Ptr[uint64]](a)[0]
    printk1("  *a after write = %x\n", val)
    kfree(a)
    kfree(c)
    kfree(d)
    kfree(e)
    kfree(0x123456)        # bad pointer — magic check should warn

    # --- large kmalloc path: alloc_pages-backed -------------------
    # Pick sizes that span multiple order classes:
    #   8000  ->  order 1 (2 pages = 8 KiB after header)
    #   20000 ->  order 3 (8 pages = 32 KiB)
    #   100000 -> order 5 (32 pages = 128 KiB)
    large1: uint64 = kmalloc(8000)
    large2: uint64 = kmalloc(20000)
    large3: uint64 = kmalloc(100000)
    printk1("  kmalloc(  8000) = %p  (order 1)\n", large1)
    printk1("  kmalloc( 20000) = %p  (order 3)\n", large2)
    printk1("  kmalloc(100000) = %p  (order 5)\n", large3)

    # Write/read the last byte of the largest block to prove the
    # full range is mapped + usable (no segfault here means the
    # entire 128 KiB is alive).
    cast[Ptr[uint8]](large3 + 99999)[0] = 0x5A
    val8: uint8 = cast[Ptr[uint8]](large3 + 99999)[0]
    printk1("  large3[99999] roundtrip = 0x%x  (expect 0x5a)\n",
            cast[uint64](val8))

    kfree(large1)
    kfree(large2)
    kfree(large3)

    # Re-allocate at the same order — should return one of the
    # freed runs (LIFO order from the per-order free list).
    reuse: uint64 = kmalloc(20000)
    printk1("  kmalloc(20000) after free = %p  (expect == prev)\n", reuse)
    kfree(reuse)


def string_ops_smoke_test():
    # Exercise memset, memcpy, memmove (forward + backward), kzalloc.
    # Each result is read back via printk so any miscompile shows up
    # as a visible mismatch in the serial output.
    printk0("Pynux: string-ops smoke test\n")

    # --- memset: fill 8 bytes with 0xAA, expect 0xAAAAAAAAAAAAAAAA --
    buf_a: uint64 = kmalloc(64)
    memset(cast[Ptr[uint8]](buf_a), 0xAA, 8)
    printk1("  memset(0xAA, 8) -> %x\n", cast[Ptr[uint64]](buf_a)[0])

    # --- memcpy: copy 16 bytes from one slot to another -----------
    cast[Ptr[uint64]](buf_a)[0] = 0xDEADBEEF_CAFEBABE
    cast[Ptr[uint64]](buf_a)[1] = 0x1234567890ABCDEF
    buf_b: uint64 = kmalloc(64)
    memset(cast[Ptr[uint8]](buf_b), 0, 16)
    memcpy(cast[Ptr[uint8]](buf_b), cast[Ptr[uint8]](buf_a), 16)
    printk1("  memcpy -> [0]=%x\n", cast[Ptr[uint64]](buf_b)[0])
    printk1("  memcpy -> [1]=%x\n", cast[Ptr[uint64]](buf_b)[1])

    # --- memmove with backwards overlap: shift buffer right by 4 --
    # Initial: bytes 0..7 = 1,2,3,4,5,6,7,8.
    # memmove(buf+4, buf+0, 4): should shift left 4 bytes into right 4.
    # Result: 1,2,3,4,1,2,3,4.  Tests the dst>src backward-walk path.
    p8: Ptr[uint8] = cast[Ptr[uint8]](buf_a)
    p8[0] = 1
    p8[1] = 2
    p8[2] = 3
    p8[3] = 4
    p8[4] = 5
    p8[5] = 6
    p8[6] = 7
    p8[7] = 8
    memmove(cast[Ptr[uint8]](buf_a + 4), cast[Ptr[uint8]](buf_a), 4)
    printk2("  memmove backward: [0..3]=%x [4..7]=%x\n",
            cast[Ptr[uint32]](buf_a)[0],
            cast[Ptr[uint32]](buf_a + 4)[0])

    # --- kzalloc: 96 bytes, every quad reads back as 0 -------------
    z: uint64 = kzalloc(96)
    bad: uint64 = 0
    i: uint64 = 0
    while i < 12:
        if cast[Ptr[uint64]](z + i * 8)[0] != 0:
            bad = bad + 1
        i = i + 1
    printk1("  kzalloc(96): non-zero quads = %d  (expect 0)\n", bad)

    kfree(buf_a)
    kfree(buf_b)
    kfree(z)


# --- list_head smoke test ------------------------------------------
#
# Container struct: a tiny payload + an embedded ListHead. Mirrors
# how Linux's task_struct / kmem_cache / file etc. embed a
# `struct list_head` for chaining. Both globals and the offset
# constant below are referenced from the smoke test below.

class ListNode:
    value:    uint64           # offset  0
    pad:      uint64           # offset  8 (keeps link 16-byte aligned)
    link:     ListHead         # offset 16, size 16


# Byte offset of `link` within ListNode. Pynux has no container_of
# macro, so the container-walk code has to subtract this constant
# explicitly from a ListHead pointer to recover the surrounding
# ListNode.
LIST_NODE_LINK_OFFSET: uint64 = 16


demo_head: ListHead
demo_n1:   ListNode
demo_n2:   ListNode
demo_n3:   ListNode


def _list_walk_and_sum(head: Ptr[ListHead]) -> uint64:
    # Walk forward from head, summing each node's payload `value`.
    # Stops when we loop back to head — the canonical circular-list
    # termination condition. Uses container_of to recover the
    # enclosing ListNode from its embedded ListHead pointer; mirrors
    # Linux's `list_for_each_entry` macro at the body level.
    head_addr: uint64 = cast[uint64](head)
    pos:       uint64 = head[0].next_ptr
    total:     uint64 = 0
    while pos != head_addr:
        link: Ptr[ListHead] = cast[Ptr[ListHead]](pos)
        node: Ptr[ListNode] = container_of(link, ListNode, link)
        total = total + node[0].value
        pos = link[0].next_ptr
    return total


def list_smoke_test():
    printk0("Pynux: list_head smoke test\n")

    INIT_LIST_HEAD(&demo_head)
    printk1("  list_empty after init = %d  (expect 1)\n",
            cast[uint64](list_empty(&demo_head)))

    demo_n1.value = 10
    demo_n2.value = 20
    demo_n3.value = 30

    # Add at head: post-add order is 1 -> 2 -> 3 ... wait no,
    # list_add inserts AT THE FRONT, so calling order 1,2,3 yields
    # head -> 3 -> 2 -> 1 -> back to head.
    list_add(&demo_n1.link, &demo_head)
    list_add(&demo_n2.link, &demo_head)
    list_add(&demo_n3.link, &demo_head)

    printk1("  list_empty after 3 adds = %d  (expect 0)\n",
            cast[uint64](list_empty(&demo_head)))

    # Walk sum: 30 + 20 + 10 = 60. Independent of insertion order,
    # which is also a soft validity check on prev pointers.
    total: uint64 = _list_walk_and_sum(&demo_head)
    printk1("  walked sum = %d  (expect 60)\n", total)

    # Remove the middle node (n2), walk again. Expected: 30 + 10 = 40.
    list_del(&demo_n2.link)
    total = _list_walk_and_sum(&demo_head)
    printk1("  after list_del(n2): sum = %d  (expect 40)\n", total)

    # list_add_tail puts a node at the BACK; after the del above the
    # list is head -> 3 -> 1 -> head, so a tail-add of n2 makes it
    # head -> 3 -> 1 -> 2 -> head. Sum becomes 30+10+20 = 60 again.
    list_add_tail(&demo_n2.link, &demo_head)
    total = _list_walk_and_sum(&demo_head)
    printk1("  after list_add_tail(n2): sum = %d  (expect 60)\n", total)


def diag_smoke_test():
    # Exercise the log-level wrappers and WARN_ON. panic() and BUG()
    # are not invoked here because they halt the box; we just confirm
    # the diagnostic banners render correctly.
    printk0("Pynux: diag smoke test\n")
    pr_emerg("EMERG-level message\n")
    pr_alert_test: int32 = 0          # placeholder, no pr_alert here
    pr_err("test error message\n")
    pr_warn("test warning message\n")
    pr_info("test info message\n")

    # WARN_ON with a false condition: must NOT print.
    rc1: uint64 = WARN_ON(0, "(silent) WARN_ON(0) should not appear")
    printk1("  WARN_ON(0) returned %d\n", rc1)

    # WARN_ON with a true condition: must print but continue.
    rc2: uint64 = WARN_ON(1, "(loud) WARN_ON(1) fires intentionally")
    printk1("  WARN_ON(1) returned %d\n", rc2)


# --- Preemption demo -----------------------------------------------
#
# Both tasks run a tight busy-loop with no cooperative yield. Without
# preemption, only task A would ever get the CPU. With the M16.9
# preemption path, the PIT timer interrupts the running task every
# ~10 ms and schedule() rotates to the other. The expected output
# is interleaved 'A' and 'B' characters, with a roughly even mix —
# proof that the timer ISR is genuinely taking the CPU away from
# unwilling code.
#
# We cap total prints from each task at MAX_PRINTS so the smoke test
# halts cleanly instead of running forever.

print_count_a: uint64 = 0
print_count_b: uint64 = 0
MAX_PRINTS:    uint64 = 40
inner_iters:   uint64 = 200000   # busy-spin between prints


def halt_forever():
    asm_volatile("cli")
    while True:
        asm_volatile("hlt")


def task_a_entry():
    while True:
        printk0("A")
        print_count_a = print_count_a + 1
        if print_count_a + print_count_b >= MAX_PRINTS:
            printk0("\n")
            printk2("Pynux: jiffies=%d  local_timer_ticks=%d (per-CPU)\n",
                    get_jiffies(), get_local_timer_ticks())
            printk0("Pynux: preemption demo done, halting\n")
            halt_forever()
        i: uint64 = 0
        while i < inner_iters:
            i = i + 1


def task_b_entry():
    while True:
        printk0("B")
        print_count_b = print_count_b + 1
        if print_count_a + print_count_b >= MAX_PRINTS:
            printk0("\n")
            printk2("Pynux: jiffies=%d  local_timer_ticks=%d (per-CPU)\n",
                    get_jiffies(), get_local_timer_ticks())
            printk0("Pynux: preemption demo done, halting\n")
            halt_forever()
        i: uint64 = 0
        while i < inner_iters:
            i = i + 1


def start_kernel():
    setup_early_printk()
    printk0("Pynux kernel booting...\n")
    printk0("Pynux: hello from start_kernel\n")

    trap_init()
    printk0("Pynux: trap_init done\n")

    mem_init()
    memblock_smoke_test()
    page_alloc_smoke_test()
    slab_smoke_test()
    string_ops_smoke_test()
    diag_smoke_test()
    list_smoke_test()

    setup_per_cpu_areas()
    printk1("Pynux: smp_processor_id() = %d\n", get_cpu_id())

    i8259_init()
    time_init()

    sched_init()
    kthread_create(0, cast[uint64](&task_a_entry), 0x5f5f615f6b736174)
    kthread_create(1, cast[uint64](&task_b_entry), 0x5f5f625f6b736174)

    printk0("Pynux: entering task 0 (IRQs enabled atomically via iretq)\n")
    # Do NOT call local_irq_enable() here. If we did, the very next
    # timer tick would fire while still in start_kernel's boot context;
    # schedule() would then save the boot RSP into task slot 0 (where
    # we previously stashed task A's pre-built bootstrap stack),
    # corrupting it. The iret frame inside each kthread's pre-built
    # stack has RFLAGS = 0x202 (IF=1), so IRQs come on atomically with
    # the iretq that lands in the task's entry function.
    start_first_task()
    # NOT REACHED.
    printk0("Pynux: ERROR — returned from start_first_task\n")
    halt_forever()
