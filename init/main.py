# init/main.py
#
# Pynux start_kernel() — mirrors init/main.c in Linux. Called from
# arch/x86/kernel/head_64.S:start_kernel_asm_entry after BSS is zeroed.
# For M16.1 the body is: bring the early console up, print a banner,
# return. head_64.S halts the CPU on return.
#
# Future M16.x work expands this function the way Linux does in
# init/main.c — setup_arch(), trap_init(), mm_init(), sched_init(), and
# eventually rest_init() / kernel_init(). We keep the function name and
# call ordering aligned with Linux so the diff against init/main.c stays
# readable as more subsystems land.

from drivers.tty.serial.early_8250 import setup_early_printk, early_puts


def start_kernel():
    setup_early_printk()
    early_puts("Pynux kernel booting...\n")
    early_puts("Pynux: hello from start_kernel\n")
    early_puts("Pynux: M16.1 boot path verified, halting.\n")
