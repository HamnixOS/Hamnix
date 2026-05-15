# arch/x86/kernel/setup_percpu.py
#
# Mirrors arch/x86/kernel/setup_percpu.c in Linux. Brings the per-CPU
# subsystem online by allocating a per-CPU area for each CPU (just the
# boot CPU for M16.4 — SMP startup comes later) and anchoring %gs at
# its base so accesses of the form `mov %gs:offset, reg` land in the
# right area.
#
# Per-CPU layout (M16.4 minimal):
#   offset  0: cpu_id (uint64, this CPU's logical id)
#   offset  8..PCPU_AREA_SIZE: reserved for future per-CPU statics
#
# The full Linux layout is driven by .data..percpu section linkage and
# a load-time copy; we'll re-derive that once we have a section
# allocator. For now a single fixed area for CPU 0 is enough to prove
# %gs-based access end-to-end.

from mm.memblock import memblock_alloc
from drivers.tty.serial.early_8250 import (
    early_puts, early_print_hex64,
)

extern def wrmsr_gsbase(value: uint64)
extern def read_cpu_id_percpu() -> uint64

# Page-sized area is overkill for one u64 but matches Linux's per-CPU
# page convention and leaves room for the second per-CPU variable.
PCPU_AREA_SIZE: uint64 = 4096

# Saved pointer to the boot CPU's per-CPU area, kept globally so later
# code (and debug dumps) can find it without re-reading the GS MSR.
boot_pcpu_area: uint64 = 0


def setup_per_cpu_areas():
    # Mirrors setup_per_cpu_areas() in Linux's setup_percpu.c — but
    # since we have one CPU and no .data..percpu section yet, the
    # body is: allocate one page-aligned area, init cpu_id = 0,
    # point %gs at it.
    area: uint64 = memblock_alloc(PCPU_AREA_SIZE, 4096)
    if area == 0:
        # No more memblock memory — fatal during early boot.
        early_puts("Pynux: setup_per_cpu_areas OOM\n")
        asm_volatile("cli")
        while True:
            asm_volatile("hlt")

    # Store logical CPU id at offset 0. We treat the returned address
    # as a Ptr[uint64] by writing through a cast. (Pynux globals living
    # at a numeric address would need a `volatile`-style intrinsic; for
    # M16.4 we just access via raw pointer arithmetic from Pynux —
    # which the codegen lowers to a plain `movq imm, %rax; movq $val,
    # (%rax)`.)
    cpu_id_slot: Ptr[uint64] = cast[Ptr[uint64]](area)
    cpu_id_slot[0] = 0

    boot_pcpu_area = area
    wrmsr_gsbase(area)

    early_puts("Pynux: per-CPU area @ 0x")
    early_print_hex64(area)
    early_puts("\n")


def get_cpu_id() -> uint64:
    # smp_processor_id() equivalent: read CPU id from %gs:0.
    return read_cpu_id_percpu()
