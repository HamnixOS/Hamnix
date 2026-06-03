/*
 * arch/x86/kernel/head_64.S - Hamnix 64-bit kernel entry (higher-half).
 *
 * Mirrors Linux's arch/x86/kernel/head_64.S: the first 64-bit code
 * that runs as "the kernel proper". By the time control reaches here
 * RIP is already executing in the HIGHER HALF (0xffffffff80000000+):
 *
 *   - Multiboot1/BIOS path: arch/x86/boot/header.S's long_mode_start
 *     does `movabsq $start_kernel_asm_entry; jmpq *%rax`, which lands
 *     RIP at the high-half VMA of start_kernel_asm_entry below.
 *   - UEFI path: arch/x86/boot/efi_stub.S builds page tables with the
 *     same PML4[0] low-identity + PML4[511] high-half split, then
 *     far-jumps to the high-half VMA of _x86_start_after_loader.
 *
 * Two entry points:
 *
 *   1. start_kernel_asm_entry — multiboot1 entry. Zeroes the high-half
 *      .bss, then falls through to the common path.
 *
 *   2. _x86_start_after_loader — common post-loader path. The UEFI
 *      path's firmware already NOBITS-zeroes the image .bss, so the
 *      EFI stub jumps here directly (skipping the redundant re-zero).
 *
 * Responsibilities of the common path: call start_kernel(); halt if it
 * ever returns. GDT / CR3 / page tables are programmed by the loader.
 *
 * All symbols here are linked in the higher half; RIP-relative
 * references (R_X86_64_PC32) between high-half code and high-half data
 * resolve cleanly. The kernel is a true elf64-x86-64 object, so the
 * full 64-bit absolute relocations (R_X86_64_64) used elsewhere for
 * higher-half symbol address words are representable too.
 */

    .section .text, "ax"
    .code64

    .globl  start_kernel_asm_entry
start_kernel_asm_entry:
    /* Zero the high-half kernel BSS: [__bss_start, __bss_end). Both
     * symbols are higher-half VMAs defined by kernel.lds; we run in
     * the higher half, so leaq RIP-relative reaches them directly.
     * `rep stosq` — the linker aligns both ends to 8. */
    leaq    __bss_start(%rip), %rdi
    leaq    __bss_end(%rip),   %rcx
    subq    %rdi, %rcx
    shrq    $3, %rcx
    xorl    %eax, %eax
    cld
    rep stosq

    /* Fall through to the common post-loader path. */

    /* _x86_start_after_loader_high — the HIGH-half common post-loader
     * path. The multiboot1 path falls through from
     * start_kernel_asm_entry above. The UEFI path arrives here via the
     * LOW shim `_x86_start_after_loader` (arch/x86/boot/header.S):
     * the EFI handoff table can only carry a 32-bit address, so it
     * points the firmware at the low shim, which `movabsq`-jumps up
     * to here. */
    .globl  _x86_start_after_loader_high
_x86_start_after_loader_high:
    /* Common path. Hand off to the Hamnix kernel. SysV AMD64: no args,
     * no return value. start_kernel() walks boot info and brings every
     * subsystem up. */
    call    start_kernel

    /* If start_kernel returns (it shouldn't yet), halt forever. */
halt_loop:
    cli
    hlt
    jmp     halt_loop

/* ---------- kernel_image_end() ----------------------------------- *
 * Returns the PHYSICAL address one past the last byte the kernel
 * image occupies in low RAM. mm/memblock callers bump their pool's
 * base past this so freshly-allocated pages can't overlap the kernel
 * .text/.rodata/.data/.pgtables/.bss.
 *
 * Higher-half subtlety: __bss_end is a high VMA (0xffffffff80...), but
 * memblock needs a PHYSICAL address. The kernel image is LINKED high
 * but LOADED low; the high-half base 0xffffffff80000000 maps to
 * physical 0 (see header.S pdpt_high). So:
 *
 *     phys(__bss_end) = __bss_end - KERNEL_VBASE
 *
 * The .bss is NOBITS — it has no LMA file bytes — but it is the last
 * thing the image needs zero-backed RAM for, and the loader reserves
 * [LMA(.bss), LMA(.bss)+memsz). Its physical extent therefore ends at
 * (__bss_end - KERNEL_VBASE).
 *
 * KERNEL_VBASE = 0xffffffff80000000. We compute the subtraction with
 * a movabsq immediate (R_X86_64_64-free — it's a plain constant) so no
 * relocation is involved. __bss_end's address is loaded RIP-relative. */
    .equ KERNEL_VBASE_HI, 0xffffffff80000000

    .section .text, "ax"
    .align 16
    .globl kernel_image_end
kernel_image_end:
    leaq    __bss_end(%rip), %rax
    movabsq $KERNEL_VBASE_HI, %rcx
    subq    %rcx, %rax
    ret

/* ---------- kernel_text_start() / kernel_text_end() -------------- *
 * Return the HIGH-VMA bounds of the kernel .text section as linked by
 * kernel.lds (__kernel_text_start / __kernel_text_end). Unlike
 * kernel_image_end() above — which subtracts KERNEL_VBASE to hand
 * memblock a PHYSICAL address — these return the addresses UNTOUCHED,
 * i.e. the same 0xffffffff80...... values the CPU pushes as return
 * addresses onto the stack. dump_stack() (kernel/panic.ad) uses them
 * to (a) validate that a candidate %rbp+8 word lands inside kernel
 * .text before trusting it as a return address, and (b) print the
 * text base so an operator can offline-symbolize raw addresses against
 * the build's unstripped ELF.
 *
 * __kernel_text_end is the linker's __bss_end-adjacent marker placed
 * AFTER .data/.bss (see kernel.lds line 180); for validating return
 * addresses any address below it and at/above __kernel_text_start is
 * "inside the image", which is the conservative bound we want — a
 * looser-than-strict-.text bound never produces a FALSE return-address
 * acceptance for a frame-pointer walk (the saved RIP is genuine), it
 * only affects the best-effort scan fallback, which we do not use. */
    .section .text, "ax"
    .align 16
    .globl kernel_text_start
kernel_text_start:
    leaq    __kernel_text_start(%rip), %rax
    ret

    .align 16
    .globl kernel_text_end
kernel_text_end:
    leaq    __kernel_text_end(%rip), %rax
    ret

/* ---------- read_rbp() ------------------------------------------- *
 * Return the CALLER's frame-pointer (%rbp) so dump_stack() can start
 * walking the saved-%rbp linked list. This is a LEAF helper with NO
 * prologue of its own: it does not `pushq %rbp` / `movq %rsp,%rbp`,
 * so on entry %rbp still holds the caller's frame pointer, which we
 * hand back in %rax untouched. (Adder-emitted functions always frame
 * with %rbp — see compiler/codegen_x86.py:21 — so the caller's %rbp
 * is a valid frame whose [%rbp]=saved-caller-rbp and [%rbp+8]=return
 * address, the chain dump_stack walks.) */
    .align 16
    .globl read_rbp
read_rbp:
    movq    %rbp, %rax
    ret
