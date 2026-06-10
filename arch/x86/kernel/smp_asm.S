/*
 * arch/x86/kernel/smp_asm.S - AP 64-bit landing + accessors.
 *
 * The AP boot trampoline (arch/x86/realmode/trampoline.S) far-jumps
 * into `ap_main_64` after reaching long mode on the AP. This file
 * houses that landing function and a couple of small accessors the
 * Hamnix SMP layer needs but can't express directly:
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
 *                                     Calls Hamnix ap_main_hamnix().
 */

    .code64
    .section .text, "ax"

    .align 16
    .globl get_bsp_cr3
get_bsp_cr3:
    movq    %cr3, %rax
    ret

/* load_cr3(value): mov %rdi, %cr3.
 *
 * Used by schedule() to switch task page tables. The CR3 write
 * implicitly flushes non-global TLB entries — Linux is careful to
 * minimise these writes (via PCID / lazy TLB) for that reason, but
 * for M16.28 we just take the hit; correctness first.
 */
    .align 16
    .globl load_cr3
load_cr3:
    movq    %rdi, %cr3
    ret

/* read_cr0() -> uint64: snapshot the current CR0.
 *
 * M16.155-cr0-probe: Asus ring-3-transition triple-fault diagnostic.
 * Both IRETQ (M16.154-eft) and SYSRETQ (M16.155) triple-fault on this
 * silicon, and none of the trap-diag handlers fire — so the candidate
 * shifts to "user code IS executing, but the very first instruction
 * traps in a vector we don't yet override (e.g. #NM / #MF / #XF for
 * an FPU/SIMD op masked by CR0.TS or CR0.EM)". Surface CR0 so the
 * next capture confirms or refutes that hypothesis directly.
 *
 * Pure read, no side effects, callable from any CPL=0 context.
 */
    .align 16
    .globl read_cr0
read_cr0:
    movq    %cr0, %rax
    ret

/* read_cr4() -> uint64: snapshot the current CR4.
 *
 * M16.154 (Asus iretq triple-fault diagnostic): real silicon enforces
 * SMEP / SMAP / OSXSAVE etc. that QEMU TCG enables more permissively.
 * Surfacing the live CR4 in the ring-3-transition serial dump lets the
 * next real-hardware capture confirm/refute whether a CR4-controlled
 * protection bit is firing on the very first CPL=3 instruction fetch
 * (e.g. CR4.SMEP=1 + a leaf with US=1 is the documented combination
 * that triple-faults a CPL=0 ifetch — symmetric reasoning here:
 * surfacing CR4.SMAP=1 with an iretq into a user page reachable from
 * supervisor code lights up the same blast-radius if any kernel path
 * accidentally touches user memory before the iretq pops to CPL=3).
 *
 * Pure read, no side effects, callable from any CPL=0 context.
 */
    .align 16
    .globl read_cr4
read_cr4:
    movq    %cr4, %rax
    ret

/* Generic MSR access (read_msr / write_msr) lives in
 * arch/x86/kernel/syscall_64.S. The PAT (IA32_PAT = 0x277) setup in
 * arch/x86/mm/pgtable.ad declares them `extern` and reuses those. */

/* The linker symbols __ap_trampoline_load / __ap_trampoline_size and
 * the trampoline-local ap_cr3_value / ap_landing_addr / ap_stack_top
 * are absolute values we can't name directly from Adder. We stash
 * them as link-time-resolved words in .rodata and expose accessors.
 *
 * HIGHER-HALF: these are stored as `.quad sym` (R_X86_64_64) rather
 * than `.long sym`. __ap_trampoline_load is a low physical LMA and
 * ap_* are .ap_trampoline symbols at VMA 0x8000 — both fit in 32 bits
 * — but storing every linker-symbol word uniformly as a 64-bit quad
 * keeps the encoding correct regardless of which half a symbol lands
 * in, and the kernel is a true elf64 object so .quad sym is valid.
 * The accessors load with movq. */
    .section .rodata
    .align 8
__ap_trampoline_load_word:
    .quad __ap_trampoline_load
__ap_trampoline_size_word:
    .quad __ap_trampoline_size
__ap_cr3_value_addr_word:
    .quad ap_cr3_value
__ap_landing_addr_addr_word:
    .quad ap_landing_addr
__ap_stack_top_addr_word:
    .quad ap_stack_top
__ap_cpu_id_addr_word:
    .quad ap_cpu_id_slot

    .section .text, "ax"

    .align 16
    .globl ap_trampoline_load_addr
ap_trampoline_load_addr:
    leaq    __ap_trampoline_load_word(%rip), %rax
    movq    (%rax), %rax
    ret

    .align 16
    .globl ap_trampoline_size
ap_trampoline_size:
    leaq    __ap_trampoline_size_word(%rip), %rax
    movq    (%rax), %rax
    ret

    .align 16
    .globl ap_cr3_value_addr
ap_cr3_value_addr:
    leaq    __ap_cr3_value_addr_word(%rip), %rax
    movq    (%rax), %rax
    ret

    .align 16
    .globl ap_landing_addr_addr
ap_landing_addr_addr:
    leaq    __ap_landing_addr_addr_word(%rip), %rax
    movq    (%rax), %rax
    ret

    .align 16
    .globl ap_stack_top_addr
ap_stack_top_addr:
    leaq    __ap_stack_top_addr_word(%rip), %rax
    movq    (%rax), %rax
    ret

    .align 16
    .globl ap_cpu_id_slot_addr
ap_cpu_id_slot_addr:
    leaq    __ap_cpu_id_addr_word(%rip), %rax
    movq    (%rax), %rax
    ret

/* ---------- ap_main_64: 64-bit AP entry --------------------------
 * Trampoline jumps here once paging + long mode are live on the AP.
 * The AP already has a valid kernel stack (set from ap_stack_top by
 * the trampoline) and is sharing the BSP's page tables via CR3.
 *
 * CRITICAL: the AP arrives here with CS loaded from the TRAMPOLINE GDT
 * (selector 0x18 = 64-bit code in ap_gdt16).  Any iretq that restores
 * CS=0x08 (the Hamnix kernel CS) would consult the TRAMPOLINE GDT where
 * 0x08 is a 32-bit code segment, silently switching the AP into 32-bit
 * compatibility mode.  Reload the kernel GDT (gdt64) here so that
 * CS=0x08 is the correct 64-bit kernel code segment, identical to the
 * BSP's view.  We use a 10-byte GDT descriptor (.word limit + .quad base)
 * because in 64-bit mode lgdt reads a 10-byte operand.  */
    .align 16
    .globl ap_main_64
ap_main_64:
    /* Reload the kernel GDT so CS=0x08 means 64-bit kernel code. */
    leaq    __ap_kernel_gdt_descriptor(%rip), %rax
    lgdt    (%rax)
    /* Flush CS by a far return: push 0x08:ap_gdt_flushed onto the stack
     * and lretq into the continuation label.  This atomically loads CS
     * from the kernel GDT without a separate ljmp instruction. */
    leaq    ap_gdt_flushed(%rip), %rax
    pushq   $0x08          /* kernel CS (64-bit code in kernel GDT) */
    pushq   %rax
    lretq

ap_gdt_flushed:
    /* CS is now 0x08 from the kernel GDT.  Reload data segments too. */
    movw    $0x10, %ax
    movw    %ax, %ds
    movw    %ax, %es
    movw    %ax, %ss
    /* FS and GS will be set up by setup_ap_percpu_area() / ap_main_hamnix.
     * Zero them here so any accidental %fs/%gs-relative read before
     * setup faults cleanly rather than aliasing unknown memory. */
    xorw    %ax, %ax
    movw    %ax, %fs
    movw    %ax, %gs
    call    ap_main_hamnix
    /* Defensive: if ap_main_hamnix ever returns, halt the AP. */
1:  cli
    hlt
    jmp 1b

    /* 10-byte GDT descriptor for 64-bit mode lgdt (2-byte limit + 8-byte
     * base).  Points at the same gdt64 table the BSP loaded at boot. */
    .section .rodata
    .align 8
__ap_kernel_gdt_descriptor:
    .word   0x0037          /* limit = 7 entries * 8 - 1 = 55 = 0x37 */
    .quad   gdt64           /* 64-bit base of the kernel GDT */
