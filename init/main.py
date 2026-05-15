# init/main.py
#
# Pynux start_kernel() — mirrors init/main.c in Linux. Called from
# arch/x86/kernel/head_64.S:start_kernel_asm_entry after BSS is zeroed.
# Future M16.x work expands this function the way Linux does in
# init/main.c — setup_arch(), trap_init(), mm_init(), sched_init(), and
# eventually rest_init() / kernel_init(). We keep the function name and
# call ordering aligned with Linux so the diff against init/main.c
# stays readable.
#
# As of M16.3:
#   - setup_early_printk() → drivers/tty/serial/early_8250.py
#   - trap_init()          → arch/x86/kernel/idt.py
#   - mem_init()           → arch/x86/mm/init.py (memblock bring-up)
#   - Smoke tests: three memblock allocations + INT3.

from drivers.tty.serial.early_8250 import (
    setup_early_printk, early_puts, early_print_hex64,
)
from arch.x86.kernel.idt import idt_init
from arch.x86.kernel.traps import do_trap   # exported so common_trap sees it
from arch.x86.mm.init import mem_init
from mm.memblock import memblock_alloc, memblock_used, memblock_avail

extern def trigger_int3()


def trap_init():
    # Mirrors trap_init() in arch/x86/kernel/traps.c — sets up the IDT.
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

    early_puts("  used  = 0x")
    early_print_hex64(memblock_used())
    early_puts("\n")
    early_puts("  avail = 0x")
    early_print_hex64(memblock_avail())
    early_puts("\n")


def start_kernel():
    setup_early_printk()
    early_puts("Pynux kernel booting...\n")
    early_puts("Pynux: hello from start_kernel\n")

    trap_init()
    early_puts("Pynux: trap_init done\n")

    mem_init()
    early_puts("Pynux: mem_init done\n")

    memblock_smoke_test()

    early_puts("Pynux: triggering INT3 (trap path final smoke)\n")
    trigger_int3()

    early_puts("Pynux: ERROR — returned from trigger_int3\n")
