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
# As of M16.2:
#   - setup_early_printk()  → drivers/tty/serial/early_8250.py
#   - trap_init() (→ idt_init() in arch/x86/kernel/idt.py)
#   - Smoke test: trigger INT3 to confirm the trap path is alive.
#     The do_trap handler prints "TRAP: vector 0x03 err=0x00" and
#     halts; if the handler is wrong we'd triple-fault and reset.

from drivers.tty.serial.early_8250 import setup_early_printk, early_puts
from arch.x86.kernel.idt import idt_init
from arch.x86.kernel.traps import do_trap   # exported so common_trap sees it

extern def trigger_int3()


def trap_init():
    # Mirrors trap_init() in arch/x86/kernel/traps.c — sets up the IDT.
    # Linux additionally registers per-vector handlers and IST stacks
    # here; we have one common handler so this is currently a thin
    # wrapper around idt_init().
    idt_init()


def start_kernel():
    setup_early_printk()
    early_puts("Pynux kernel booting...\n")
    early_puts("Pynux: hello from start_kernel\n")

    trap_init()
    early_puts("Pynux: trap_init done, triggering INT3\n")

    # Smoke test: this should land in do_trap with vector=3.
    trigger_int3()

    # We do NOT expect to reach here — do_trap halts.
    early_puts("Pynux: ERROR — returned from trigger_int3\n")
