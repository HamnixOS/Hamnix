/*
 * arch/x86/kernel/cpu_entry_area_asm.S — address accessors for the KPTI
 * cpu_entry_area builder (arch/x86/mm/pgtable.ad).
 *
 * KPTI #94, Brick A: the cpu_entry_area collects the pages the CPU touches
 * on a CPL3->CPL0 transition BEFORE the entry trampoline could switch CR3 —
 * the entry .text stubs, the IDT, the per-CPU GDT/TSS, the #DF IST stacks,
 * and the MDS VERW selector word — and aliases them at a dedicated,
 * kernel-private VA window (PML4[274]) that the future user CR3 will also
 * carry. The builder needs the kernel VAs of those structures; these leaf
 * helpers hand them back (movabsq $sym absolute-loads the linked address,
 * so no ±2 GiB %rip-relative reach limit applies).
 *
 * Each is a LEAF: one movabsq + ret, no prologue, no memory access. Safe to
 * call at any point in boot. The symbols themselves are defined elsewhere:
 *   idt_table         — arch/x86/kernel/idt.ad (Adder module .bss global)
 *   per_cpu_tss/gdt   — arch/x86/kernel/tss_asm.S
 *   per_cpu_df_stack  — arch/x86/kernel/tss_asm.S
 *   mds_verw_sel      — arch/x86/kernel/syscall_64.S (.rodata)
 *   __kernel_text_start / __kernel_text_only_end — arch/x86/kernel/kernel.lds
 */

    .code64
    .section .text, "ax"

    .align 16
    .globl cea_idt_addr
cea_idt_addr:
    movabsq $idt_table, %rax
    ret

    .align 16
    .globl cea_tss_addr
cea_tss_addr:
    movabsq $per_cpu_tss, %rax
    ret

    .align 16
    .globl cea_gdt_addr
cea_gdt_addr:
    movabsq $per_cpu_gdt, %rax
    ret

    .align 16
    .globl cea_df_stack_addr
cea_df_stack_addr:
    movabsq $per_cpu_df_stack, %rax
    ret

    .align 16
    .globl cea_verw_addr
cea_verw_addr:
    movabsq $mds_verw_sel, %rax
    ret

    .align 16
    .globl cea_entry_text_start
cea_entry_text_start:
    movabsq $__kernel_text_start, %rax
    ret

    .align 16
    .globl cea_entry_text_end
cea_entry_text_end:
    movabsq $__kernel_text_only_end, %rax
    ret
