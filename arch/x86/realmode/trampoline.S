/*
 * arch/x86/realmode/trampoline.S - AP boot trampoline (real -> long).
 *
 * Mirrors arch/x86/realmode/rm/trampoline_64.S in Linux. SIPI dropped
 * the AP at CS=0x0800:IP=0x0000 (physical 0x8000) in 16-bit real mode.
 * From here we need to transition all the way to 64-bit long mode and
 * jump into the Hamnix-side `ap_main_64` landing function.
 *
 * The trampoline is linked with VMA=0x8000 but LMA inside the loaded
 * kernel image (see kernel.lds). The BSP memcpys the bytes to 0x8000
 * before sending SIPI, so by the time the AP runs them the symbol
 * addresses (which the linker resolved against VMA=0x8000) actually
 * reach valid memory.
 *
 * Per-AP parameters that the BSP plants in this trampoline before
 * INIT-SIPI-SIPI:
 *   ap_cr3_value    physical address of the page table to load
 *                   (same value BSP has in CR3 → shared PML4 -> PDPT
 *                   -> 4 GiB identity map)
 *   ap_landing_addr 64-bit kernel-space address to far-jump into
 *                   once we're in long mode (typically &ap_main_64)
 *   ap_stack_top    virtual address to load into RSP before the jump
 */

    .section .ap_trampoline, "ax", @progbits
    .code16

/* ===== Stage 1: 16-bit real mode ================================ */

    .globl ap_trampoline_start
ap_trampoline_start:
    cli
    cld

    /* CS is whatever SIPI set it to (0x08 if BSP sent SIPI vector 0x08).
     * Copy CS into DS so %ds-relative segment-offset addressing works
     * for the trampoline's own globals. */
    movw    %cs, %ax
    movw    %ax, %ds

    /* Load 16-bit GDT. The descriptor's base is the linker-resolved
     * VMA of ap_gdt16 (= 0x8000 + offset), which is exactly what the
     * CPU sees in physical memory at this point. */
    lgdtl   ap_gdt_descriptor_lm - ap_trampoline_start

    /* Enable PE (bit 0 of CR0) to enter 32-bit protected mode. */
    movl    %cr0, %eax
    orl     $1, %eax
    movl    %eax, %cr0

    /* Far jump to flush prefetch + load 32-bit CS. ljmpl with the
     * 0x66 operand-size prefix encodes a 32-bit offset + 16-bit
     * selector. Selector 0x08 in our trampoline GDT is the 32-bit
     * code segment. */
    .byte   0x66, 0xEA
    .long   ap_trampoline_pm        /* 32-bit offset (absolute VMA) */
    .word   0x08                    /* selector                     */

/* ===== Stage 2: 32-bit protected mode =========================== */

    .code32
ap_trampoline_pm:
    /* Reload data segments with the 32-bit data selector. */
    movw    $0x10, %ax
    movw    %ax, %ds
    movw    %ax, %es
    movw    %ax, %fs
    movw    %ax, %gs
    movw    %ax, %ss

    /* CR3 = BSP's page table physical address (planted by BSP). */
    movl    ap_cr3_value, %eax
    movl    %eax, %cr3

    /* Enable PAE (CR4.PAE = bit 5). */
    movl    %cr4, %eax
    orl     $(1 << 5), %eax
    /* U13: enable SSE/SSE2 on this AP too — match BSP's CR4 state from
     * arch/x86/boot/header.S so user threads scheduled onto an AP can use
     * xmm registers without trapping #UD. See the BSP path for rationale.
     *   bit 9  CR4.OSFXSR
     *   bit 10 CR4.OSXMMEXCPT  */
    orl     $(1 << 9) | (1 << 10), %eax
    movl    %eax, %cr4

    /* Enable long-mode in EFER (EFER.LME = bit 8 of MSR 0xC0000080).
     * W^X Stage 1a: also set EFER.NXE (bit 11) so this AP can load PTEs
     * with bit 63 (NX) set without taking a reserved-bit #PF. NXE must
     * be live before paging is enabled / any user NX data page is
     * mapped on this CPU — folding it into the same wrmsr as LME does
     * exactly that. */
    movl    $0xC0000080, %ecx
    rdmsr
    orl     $(1 << 8) | (1 << 11), %eax
    wrmsr

    /* Enable paging — turns on long-mode since LME was set. */
    movl    %cr0, %eax
    orl     $(1 << 31), %eax
    /* U13: normalise CR0 for SSE on the AP (see BSP path for rationale).
     *   bit 1 CR0.MP = 1
     *   bit 2 CR0.EM = 0
     *   bit 3 CR0.TS = 0  */
    orl     $(1 << 1), %eax
    andl    $~((1 << 2) | (1 << 3)), %eax
    movl    %eax, %cr0

    /* Far jump to flush prefetch + load 64-bit CS (selector 0x18 in
     * the trampoline GDT). */
    ljmpl   $0x18, $ap_trampoline_lm

/* ===== Stage 3: 64-bit long mode ================================ */

    .code64
ap_trampoline_lm:
    /* Reload data segments (in long mode the descriptors are mostly
     * ignored for DS/ES/FS/GS/SS but the registers must still hold a
     * loadable selector). Use 0x10 = 32-bit data — its descriptor is
     * loadable in long mode too. */
    movw    $0x10, %ax
    movw    %ax, %ds
    movw    %ax, %es
    movw    %ax, %fs
    movw    %ax, %gs
    movw    %ax, %ss

    /* Load AP's kernel stack pointer (planted by BSP) and the kernel-
     * mode landing address. Use leaq RIP-relative — the trampoline
     * lives at VMA 0x8000, and the linker's PC32 relocation for
     * symbols inside the same section fits cleanly in elf32-i386.
     * (movabsq with a symbol would generate a 64-bit absolute
     * relocation that the wrapper can't represent.) */
    leaq    ap_stack_top(%rip), %rax
    movq    (%rax), %rsp
    leaq    ap_landing_addr(%rip), %rax
    movq    (%rax), %rax
    jmpq    *%rax

/* ===== Trampoline-local GDT + descriptor ======================== *
 * Three useful selectors:
 *   0x08 = 32-bit code (PE-to-PG handoff)
 *   0x10 = 32-bit data (PE-mode data segments)
 *   0x18 = 64-bit code (long-mode handoff)
 */
    .balign 8
ap_gdt16:
    .quad   0x0000000000000000      /* 0x00: null                   */
    .quad   0x00CF9A000000FFFF      /* 0x08: 32-bit code            */
    .quad   0x00CF92000000FFFF      /* 0x10: 32-bit data            */
    .quad   0x00AF9A000000FFFF      /* 0x18: 64-bit code (L=1)      */
ap_gdt16_end:

ap_gdt_descriptor_lm:
    .word   ap_gdt16_end - ap_gdt16 - 1
    .long   ap_gdt16                /* base (32-bit; trampoline VMA) */

/* ===== Trampoline-local data (planted by BSP) =================== *
 * These quads are read in 32-bit / 64-bit code paths above. BSP
 * writes them just before sending INIT-SIPI-SIPI; the linker
 * places them at known offsets within the trampoline so the BSP
 * (Hamnix side) can compute their physical address as
 *      0x8000 + (label - ap_trampoline_start).
 */
    .balign 8
    .globl ap_cr3_value
ap_cr3_value:
    .quad   0
    .globl ap_landing_addr
ap_landing_addr:
    .quad   0
    .globl ap_stack_top
ap_stack_top:
    .quad   0
    .globl ap_cpu_id_slot
ap_cpu_id_slot:
    .quad   0

    .globl ap_trampoline_end
ap_trampoline_end:
