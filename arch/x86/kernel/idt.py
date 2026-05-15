# arch/x86/kernel/idt.py
#
# Mirrors arch/x86/kernel/idt.c in Linux. Owns the 256-entry IDT and
# the per-gate setup logic. The low-level per-vector entry stubs live
# in arch/x86/kernel/idt_asm.S (`trap_stub_0` ... `trap_stub_31`,
# indexed via `get_trap_stub`); this file populates the gate
# descriptors and loads them with `idt_load`.
#
# x86_64 IDT gate descriptor (16 bytes per entry):
#
#   Quad 0 (low):
#     bits  0..15  offset_low   (handler bits 0..15)
#     bits 16..31  selector     (CS for the handler, 0x08 in our GDT)
#     bits 32..34  IST          (0 — keep the interrupted stack)
#     bits 35..39  reserved
#     bits 40..47  type_attr    (0x8E = present | DPL=0 | 64-bit
#                                       interrupt gate)
#     bits 48..63  offset_mid   (handler bits 16..31)
#
#   Quad 1 (high):
#     bits  0..31  offset_high  (handler bits 32..63)
#     bits 32..63  reserved
#
# Layout is intentionally close to `gate_struct` in Linux's
# arch/x86/include/asm/desc_defs.h so future readers can diff.

extern def get_trap_stub(vector: uint64) -> uint64
extern def get_irq_stub(vector: uint64) -> uint64
extern def idt_load(idt_table_addr: uint64)

KERNEL_CS:      uint64 = 0x08    # 64-bit code segment in boot GDT
GATE_TYPE_ATTR: uint64 = 0x8E    # present | DPL=0 | 64-bit interrupt gate

# 256 IDT entries * 2 uint64 per entry = 512 quads (4 KiB total).
idt_table: Array[512, uint64]


def idt_set_gate(vector: uint64, handler: uint64):
    # Quad 0: offset_mid<<48 | type_attr<<40 | ist<<32 | sel<<16 | offset_low.
    # ist = 0, so we omit that term.
    q0: uint64 = handler & 0xFFFF
    q0 = q0 | (KERNEL_CS << 16)
    q0 = q0 | (GATE_TYPE_ATTR << 40)
    q0 = q0 | (((handler >> 16) & 0xFFFF) << 48)

    # Quad 1: high 32 bits of the handler (rest of the entry is zero).
    q1: uint64 = (handler >> 32) & 0xFFFFFFFF

    idx: uint64 = vector * 2
    idt_table[idx] = q0
    idt_table[idx + 1] = q1


def idt_init():
    # Vectors 0..31: CPU exceptions, halt-on-fault traps.
    i: uint64 = 0
    while i < 32:
        handler: uint64 = get_trap_stub(i)
        idt_set_gate(i, handler)
        i = i + 1

    # Vectors 32..47: legacy 8259 IRQs (after the i8259 remap). These
    # use the iretq-returning IRQ entry path, not the halt-on-fault
    # trap path. Vectors 48..255 stay Present=0 — APIC/MSI not yet
    # implemented.
    i = 32
    while i < 48:
        handler: uint64 = get_irq_stub(i)
        idt_set_gate(i, handler)
        i = i + 1

    idt_load(&idt_table)
