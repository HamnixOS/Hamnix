# arch/x86/kernel/irq.py
#
# Mirrors the parts of arch/x86/kernel/irq.c that wire vector → IRQ →
# handler. For M16.5 the dispatch table is hard-coded (we have exactly
# one IRQ handler, for the timer) — once the Pynux-side IRQ chip
# subsystem lands we'll replace this with a generic
# generic_handle_irq()-style chain.
#
# Called from arch/x86/kernel/irq_asm.S:common_irq with the CPU vector
# number in %rdi (SysV ABI). Handlers send their own EOI before
# returning so common_irq's iretq lets the interrupted context
# continue cleanly.

from arch.x86.kernel.time import timer_interrupt
from arch.x86.kernel.i8259 import i8259_send_eoi

TIMER_VECTOR: uint64 = 32   # IRQ 0 after the 0x20 PIC remap


def do_irq(vector: uint64):
    if vector == TIMER_VECTOR:
        timer_interrupt()
        return
    # Spurious / unhandled IRQ. Still ack the PIC so future ones can
    # fire; vector - 32 maps back to the legacy IRQ line number.
    i8259_send_eoi(cast[int32](vector - 32))
