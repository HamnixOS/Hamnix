# init/main.py
#
# Pynux start_kernel() — mirrors init/main.c in Linux. Called from
# arch/x86/kernel/head_64.S:start_kernel_asm_entry after BSS is zeroed.
# Future M16.x work expands this function the way Linux does in
# init/main.c — setup_arch(), trap_init(), mm_init(), sched_init(), and
# eventually rest_init() / kernel_init(). Function names and ordering
# track Linux so the diff against init/main.c stays readable.
#
# As of M16.7:
#   - setup_early_printk()       drivers/tty/serial/early_8250.py
#   - printk0/1/2                kernel/printk/printk.py (%d %x %s %p %c)
#   - trap_init()                arch/x86/kernel/idt.py
#   - mem_init()                 arch/x86/mm/init.py (memblock)
#   - setup_per_cpu_areas()      arch/x86/kernel/setup_percpu.py
#   - i8259_init() + time_init() PIC + PIT @ 100 Hz
#   - sched_init() + kthread_create()  cooperative scheduler
#
# Output now uses printk* everywhere so message formatting tracks how
# Linux phrases its early-boot log lines.

from drivers.tty.serial.early_8250 import setup_early_printk
from kernel.printk.printk import printk0, printk1, printk2
from arch.x86.kernel.idt import idt_init
from arch.x86.kernel.traps import do_trap          # exported for common_trap
from arch.x86.kernel.irq import do_irq             # exported for common_irq
from arch.x86.mm.init import mem_init
from arch.x86.kernel.setup_percpu import setup_per_cpu_areas, get_cpu_id
from arch.x86.kernel.i8259 import i8259_init
from arch.x86.kernel.time import time_init, get_jiffies
from kernel.sched.core import sched_init, kthread_create, yield_cpu
from mm.memblock import memblock_alloc, memblock_used, memblock_avail
from mm.page_alloc import alloc_page, free_page, page_alloc_total, page_alloc_free_count
from mm.slab import kmalloc, kfree

extern def trigger_int3()
extern def local_irq_enable()
extern def cpu_relax()

print_count: uint64 = 0
MAX_PRINTS:  uint64 = 30


def busy_wait_one_tick():
    start: uint64 = get_jiffies()
    while get_jiffies() == start:
        cpu_relax()


def halt_forever():
    asm_volatile("cli")
    while True:
        asm_volatile("hlt")


def task_a_entry():
    while True:
        printk0("A")
        print_count = print_count + 1
        if print_count >= MAX_PRINTS:
            printk0("\nPynux: M16.x demo done, halting\n")
            halt_forever()
        busy_wait_one_tick()
        yield_cpu()


def task_b_entry():
    while True:
        printk0("B")
        print_count = print_count + 1
        if print_count >= MAX_PRINTS:
            printk0("\nPynux: M16.x demo done, halting\n")
            halt_forever()
        busy_wait_one_tick()
        yield_cpu()


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
    # Three pages: 1st pulled fresh from memblock, freed, then a 2nd
    # alloc returns the same page (cache hit on free list). 3rd is a
    # new fresh page. Confirms both fresh-pull and freelist paths.
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
    # Exercise multiple kmalloc sizes, prove kfree reuses storage by
    # checking that a re-allocation of the same size returns a known
    # earlier address (most-recently-freed → head of free list).
    printk0("Pynux: slab smoke test\n")
    a: uint64 = kmalloc(48)        # → kmalloc-64
    b: uint64 = kmalloc(48)        # adjacent in the same slab
    c: uint64 = kmalloc(200)       # → kmalloc-256
    d: uint64 = kmalloc(1500)      # → kmalloc-2048
    printk1("  kmalloc(  48) = %p\n", a)
    printk1("  kmalloc(  48) = %p\n", b)
    printk1("  kmalloc( 200) = %p\n", c)
    printk1("  kmalloc(1500) = %p\n", d)

    # Free b, then ask for another 48 — should get b back (LIFO).
    kfree(b)
    e: uint64 = kmalloc(48)
    printk1("  kmalloc(  48) after kfree(b) = %p  (expect == b)\n", e)

    # Write and read each chunk to sanity-check the memory is usable.
    cast[Ptr[uint64]](a)[0] = 0xCAFEBABE_DEADBEEF
    val: uint64 = cast[Ptr[uint64]](a)[0]
    printk1("  *a after write = %x\n", val)

    kfree(a)
    kfree(c)
    kfree(d)
    kfree(e)
    # Double-free / wild-pointer guard.
    kfree(0x123456)                # bogus pointer; should warn loudly


def timer_smoke_test():
    printk0("Pynux: waiting for timer ticks...\n")
    last: uint64 = 0
    while True:
        cur: uint64 = get_jiffies()
        if cur != last:
            printk1("  jiffies = %d\n", cur)
            last = cur
            if cur >= 5:
                return
        cpu_relax()


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

    setup_per_cpu_areas()
    printk1("Pynux: smp_processor_id() = %d\n", get_cpu_id())

    i8259_init()
    time_init()
    printk0("Pynux: PIT @ 100 Hz armed, enabling IRQs\n")
    local_irq_enable()

    timer_smoke_test()

    sched_init()
    kthread_create(1, cast[uint64](&task_a_entry), 0x5f5f615f6b736174)
    kthread_create(2, cast[uint64](&task_b_entry), 0x5f5f625f6b736174)
    printk0("Pynux: two kthreads created, entering scheduler\n")

    while True:
        yield_cpu()
