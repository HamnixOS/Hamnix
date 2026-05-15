/*
 * arch/x86/kernel/head_64.S - Pynux 64-bit kernel entry.
 *
 * Mirrors Linux's arch/x86/kernel/head_64.S: it is the first 64-bit code
 * that runs as "the kernel proper" after the bootloader / decompressor
 * hands off. For Pynux the handoff comes from arch/x86/boot/header.S's
 * long_mode_start, which jumps here once long mode is live, segments are
 * reloaded, and the boot stack is anchored.
 *
 * Responsibilities (minimal for M16.1):
 *   1. Zero the kernel BSS (the Pynux compiler places globals there).
 *   2. Call the Pynux-emitted start_kernel().
 *   3. If start_kernel ever returns, halt the CPU.
 */

    .section .text, "ax"
    .code64

    .globl  start_kernel_asm_entry
start_kernel_asm_entry:
    /* Zero kernel BSS: [__bss_start, __bss_end). Both symbols are defined
     * by arch/x86/kernel/vmlinux.lds. Using `rep stosq` so we move 8 bytes
     * at a time; the linker script aligns __bss_start/__bss_end to 8. */
    leaq    __bss_start(%rip), %rdi
    leaq    __bss_end(%rip),   %rcx
    subq    %rdi, %rcx
    shrq    $3, %rcx
    xorl    %eax, %eax
    cld
    rep stosq

    /* Hand off to the Pynux kernel. SysV AMD64: no args, no return value. */
    call    start_kernel

    /* If start_kernel returns (it shouldn't yet), halt forever. */
halt_loop:
    cli
    hlt
    jmp     halt_loop
