# init/main.py
#
# Pynux start_kernel() — mirrors init/main.c in Linux. Called from
# arch/x86/kernel/head_64.S:start_kernel_asm_entry after BSS is zeroed.
# Future M16.x work expands this function the way Linux does in
# init/main.c — setup_arch(), trap_init(), mm_init(), sched_init(), and
# eventually rest_init() / kernel_init(). Function names and ordering
# track Linux so the diff against init/main.c stays readable.
#
# As of M16.5:
#   - setup_early_printk()       drivers/tty/serial/early_8250.py
#   - trap_init()                arch/x86/kernel/idt.py
#   - mem_init()                 arch/x86/mm/init.py (memblock)
#   - setup_per_cpu_areas()      arch/x86/kernel/setup_percpu.py
#   - i8259_init()               arch/x86/kernel/i8259.py
#   - time_init()                arch/x86/kernel/time.py (PIT @ 100 Hz)
#   - local_irq_enable() (sti)   first real interrupt-able context
#   - Polling loop watching jiffies climb confirms the timer IRQ fires.

from drivers.tty.serial.early_8250 import (
    setup_early_printk, early_puts, early_print_hex64,
)
from arch.x86.kernel.idt import idt_init
from arch.x86.kernel.traps import do_trap          # exported for common_trap
from arch.x86.kernel.irq import do_irq             # exported for common_irq
from arch.x86.mm.init import mem_init
from arch.x86.kernel.setup_percpu import setup_per_cpu_areas, get_cpu_id
from arch.x86.kernel.i8259 import i8259_init
from arch.x86.kernel.time import time_init, get_jiffies
from mm.memblock import memblock_alloc, memblock_used, memblock_avail

extern def trigger_int3()
extern def local_irq_enable()
extern def cpu_relax()


def trap_init():
    idt_init()


def memblock_smoke_test():
    early_puts("Pynux: memblock smoke test\n")
    a: uint64 = memblock_alloc(128, 16)
    early_puts("  alloc(128,16) = 0x")
    early_print_hex64(a)
    early_puts("\n")
    b: uint64 = memblock_alloc(256, 64)
    early_puts("  alloc(256,64) = 0x")
    early_print_hex64(b)
    early_puts("\n")
    c: uint64 = memblock_alloc(64, 8)
    early_puts("  alloc( 64, 8) = 0x")
    early_print_hex64(c)
    early_puts("\n")


def timer_smoke_test():
    # Spin-wait for jiffies to advance from 0 to ~10, printing each
    # tick. At 100 Hz this prints over ~100 ms; total test < 1 s.
    early_puts("Pynux: waiting for timer ticks...\n")
    last: uint64 = 0
    while True:
        cur: uint64 = get_jiffies()
        if cur != last:
            early_puts("  jiffies = 0x")
            early_print_hex64(cur)
            early_puts("\n")
            last = cur
            if cur >= 10:
                return
        cpu_relax()


def start_kernel():
    setup_early_printk()
    early_puts("Pynux kernel booting...\n")
    early_puts("Pynux: hello from start_kernel\n")

    trap_init()
    early_puts("Pynux: trap_init done\n")

    mem_init()
    memblock_smoke_test()

    setup_per_cpu_areas()
    early_puts("Pynux: smp_processor_id() = ")
    early_print_hex64(get_cpu_id())
    early_puts("\n")

    i8259_init()
    time_init()
    early_puts("Pynux: PIT @ 100 Hz armed, enabling IRQs\n")
    local_irq_enable()

    timer_smoke_test()

    early_puts("Pynux: triggering INT3 (trap path final smoke)\n")
    trigger_int3()

    early_puts("Pynux: ERROR — returned from trigger_int3\n")
