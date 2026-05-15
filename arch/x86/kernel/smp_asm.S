/*
 * arch/x86/kernel/smp_asm.S - AP 64-bit landing + accessors.
 *
 * The AP boot trampoline (arch/x86/realmode/trampoline.S) far-jumps
 * into `ap_main_64` after reaching long mode on the AP. This file
 * houses that landing function and a couple of small accessors the
 * Pynux SMP layer needs but can't express directly:
 *
 *   get_bsp_cr3()                     read CR3 on the BSP so we can
 *                                     plant it in the trampoline's
 *                                     ap_cr3_value slot.
 *
 *   ap_trampoline_load_addr()         return the LMA where the linker
 *                                     stashed the trampoline bytes.
 *
 *   ap_trampoline_size()              return the byte length.
 *
 *   ap_cr3_value_addr/                return the VMA (0x8000+offset)
 *   ap_landing_addr_addr/             of each plant-slot in the
 *   ap_stack_top_addr                 trampoline.
 *
 *   ap_main_64                        the 64-bit entry the AP jumps
 *                                     into once it's in long mode.
 *                                     Calls Pynux ap_main_pynux().
 */

    .code64
    .section .text, "ax"

    .align 16
    .globl get_bsp_cr3
get_bsp_cr3:
    movq    %cr3, %rax
    ret

/* The linker symbols __ap_trampoline_load / __ap_trampoline_start /
 * __ap_trampoline_size are abs/large values; reach them the same way
 * we reach __per_cpu_template_start - stash as .long words in .rodata
 * that get resolved at link time, then load via leaq + movl. */
    .section .rodata
    .align 4
__ap_trampoline_load_word:
    .long __ap_trampoline_load
__ap_trampoline_size_word:
    .long __ap_trampoline_size
__ap_cr3_value_addr_word:
    .long ap_cr3_value
__ap_landing_addr_addr_word:
    .long ap_landing_addr
__ap_stack_top_addr_word:
    .long ap_stack_top

    .section .text, "ax"

    .align 16
    .globl ap_trampoline_load_addr
ap_trampoline_load_addr:
    leaq    __ap_trampoline_load_word(%rip), %rax
    movl    (%rax), %eax
    ret

    .align 16
    .globl ap_trampoline_size
ap_trampoline_size:
    leaq    __ap_trampoline_size_word(%rip), %rax
    movl    (%rax), %eax
    ret

    .align 16
    .globl ap_cr3_value_addr
ap_cr3_value_addr:
    leaq    __ap_cr3_value_addr_word(%rip), %rax
    movl    (%rax), %eax
    ret

    .align 16
    .globl ap_landing_addr_addr
ap_landing_addr_addr:
    leaq    __ap_landing_addr_addr_word(%rip), %rax
    movl    (%rax), %eax
    ret

    .align 16
    .globl ap_stack_top_addr
ap_stack_top_addr:
    leaq    __ap_stack_top_addr_word(%rip), %rax
    movl    (%rax), %eax
    ret

/* ---------- ap_main_64: 64-bit AP entry --------------------------
 * Trampoline jumps here once paging + long mode are live on the AP.
 * The AP already has a valid kernel stack (set from ap_stack_top by
 * the trampoline) and is sharing the BSP's page tables via CR3.
 *
 * From here we just call into Pynux. The C-style ABI shuffle is
 * straightforward: no args, no return.  */
    .align 16
    .globl ap_main_64
ap_main_64:
    call    ap_main_pynux
    /* Defensive: if ap_main_pynux ever returns, halt the AP. */
1:  cli
    hlt
    jmp 1b
