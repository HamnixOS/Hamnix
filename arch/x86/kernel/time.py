# arch/x86/kernel/time.py
#
# Mirrors arch/x86/kernel/time.c + the PIT bits of
# arch/x86/kernel/i8253.c in Linux. Programs the 8253/8254
# Programmable Interval Timer (chip behind IRQ 0) to fire at ~100 Hz
# and exposes a Pynux-side timer interrupt handler that bumps a
# `jiffies` counter and acknowledges the PIC.
#
# Why PIT and not HPET / TSC-deadline / LAPIC timer? PIT is the
# universally-present option that needs zero ACPI parsing — perfect
# for first boot. Linux walks the same path: setup_default_timer_irq()
# falls back to PIT when nothing more capable is available.
#
# PIT divisor math:
#   PIT base = 1193182 Hz (≈ 1.193 MHz). At target HZ:
#     divisor = base / HZ = 1193182 / 100 = 11931 ≈ 0x2E9B
#   We pick 100 Hz as Linux's classic HZ; cheap, precise enough for
#   wall-clock and scheduler ticks.

from arch.x86.kernel.i8259 import i8259_send_eoi, i8259_unmask_irq
from kernel.sched.core import schedule

PIT_CHANNEL0_DATA: int32 = 0x40
PIT_CMD:           int32 = 0x43

# Command byte: channel 0, lobyte/hibyte access, mode 3 (square wave),
# binary count. = 0x36.
PIT_CMD_CH0_LOHI_MODE3: int32 = 0x36

HZ:           uint64 = 100
PIT_BASE_HZ:  uint64 = 1193182

jiffies: uint64 = 0
# Per-CPU tick counter — proves Percpu[T] codegen works for both
# read and write in interrupt context. Each CPU keeps its own count;
# on uniprocessor we expect this to track `jiffies`.
local_timer_ticks: Percpu[uint64]


def time_init():
    # Program PIT channel 0 for HZ Hz square-wave interrupts.
    divisor: uint64 = PIT_BASE_HZ / HZ
    div_lo: int32 = cast[int32](divisor & 0xFF)
    div_hi: int32 = cast[int32]((divisor >> 8) & 0xFF)

    outb(PIT_CMD_CH0_LOHI_MODE3, PIT_CMD)
    outb(div_lo, PIT_CHANNEL0_DATA)
    outb(div_hi, PIT_CHANNEL0_DATA)

    # Unmask IRQ 0 on the PIC so the timer line can actually fire.
    # CPU interrupts (EFLAGS.IF) are still off here — caller is
    # responsible for `sti` once IDT vector 32 is populated.
    i8259_unmask_irq(0)


def timer_interrupt():
    # Called from do_irq() when vector 32 (IRQ 0) fires. Bumps the
    # tick counter, acks the PIC, then surrenders the CPU to the
    # scheduler. ACK before schedule() so the next interrupt is
    # already armed by the time we return to the new task — Linux
    # has the same ordering in the legacy 8259 timer handler.
    jiffies = jiffies + 1
    # Also bump the per-CPU counter. The codegen lowers both the read
    # and the write through `%gs:local_timer_ticks` — proof the
    # Percpu[T] path works in IRQ context.
    local_timer_ticks = local_timer_ticks + 1
    i8259_send_eoi(0)
    schedule()


def get_local_timer_ticks() -> uint64:
    return local_timer_ticks


def get_jiffies() -> uint64:
    return jiffies
