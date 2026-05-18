/*
 * arch/x86/kernel/head_64.S - Hamnix 64-bit kernel entry.
 *
 * Mirrors Linux's arch/x86/kernel/head_64.S: it is the first 64-bit code
 * that runs as "the kernel proper" after the bootloader / decompressor
 * hands off. For Hamnix the handoff comes from arch/x86/boot/header.S's
 * long_mode_start, which jumps here once long mode is live, segments are
 * reloaded, and the boot stack is anchored.
 *
 * Two entry points live here:
 *
 *   1. start_kernel_asm_entry — the multiboot1 entry. arch/x86/boot/
 *      header.S's long_mode_start tail-jumps here after the 32-to-64-bit
 *      transition. Performs BSS zeroing then falls through to the
 *      common path below.
 *
 *   2. _x86_start_after_loader — the COMMON post-loader path. Any
 *      future entry point that arrives in long mode with kernel
 *      .bss already zeroed (UEFI: firmware NOBITS-zeroes our image's
 *      .bss before transferring control; PE/COFF .bss is the same
 *      NOBITS shape ELF uses) should `jmp _x86_start_after_loader`
 *      INSTEAD of `jmp start_kernel_asm_entry` — otherwise the
 *      BSS-zero loop will redundantly re-zero RAM the loader
 *      already cleared.
 *
 * Why expose the common symbol explicitly:
 *   The EFI direct-boot path (arch/x86/boot/efi_stub.S) needs a
 *   stable kernel-side hook to merge into the post-loader-specific
 *   work without re-doing the BSS-zero loop. The hook is here so
 *   that whichever path eventually unblocks UEFI-to-start_kernel
 *   handoff can use a one-line `jmp _x86_start_after_loader` rather
 *   than duplicating the post-loader plumbing.
 *
 *   Post-M16.124 honest diagnosis: the M16.120-era plan
 *   "merge the EFI stub + kernel ELF into one image" turns out to
 *   be blocked by a stack of independent constraints. The full
 *   diagnosis is recorded in arch/x86/boot/efi_stub.S's header
 *   comment (blockers B1..B4 — file-magic conflict, LMA/VMA split
 *   in .ap_trampoline, image-base relocation, GDT handoff). Two
 *   real paths forward (a UEFI-side ELF loader baked into the .efi
 *   stub, OR a separate bzImage-style flat binary) are documented
 *   there. _x86_start_after_loader remains the right join point
 *   either way — neither path needs the BSS-zero loop, both arrive
 *   in long mode with a valid kernel GDT.
 *
 * Responsibilities of the common path:
 *   1. Call the Hamnix-emitted start_kernel().
 *   2. If start_kernel ever returns, halt the CPU.
 *
 *   GDT / CR3 / page tables are NOT (re)programmed in the common
 *   path: each loader is responsible for arriving with a working
 *   long-mode environment. The multiboot1 path's header.S already
 *   loads the kernel GDT + builds the identity page tables; an
 *   eventual UEFI path will reuse those same structures (they're
 *   placed in .pgtables, NOBITS-zeroed identically).
 */

    .section .text, "ax"
    .code64

    .globl  start_kernel_asm_entry
start_kernel_asm_entry:
    /* Zero kernel BSS: [__bss_start, __bss_end). Both symbols are
     * defined by arch/x86/kernel/vmlinux.lds. Using `rep stosq` so we
     * move 8 bytes at a time; the linker script aligns __bss_start
     * and __bss_end to 8.
     *
     * Only the multiboot1 path needs this: QEMU's `-kernel` loader
     * and grub-mkrescue's multiboot1 path are supposed to NOBITS-load
     * for us, but historically not every loader has zeroed reliably
     * (some multiboot1 implementations skip NOBITS PT_LOAD segments
     * and leave stale memory). The explicit clear is defensive. */
    leaq    __bss_start(%rip), %rdi
    leaq    __bss_end(%rip),   %rcx
    subq    %rdi, %rcx
    shrq    $3, %rcx
    xorl    %eax, %eax
    cld
    rep stosq

    /* Fall through to the common post-loader path. */

    .globl  _x86_start_after_loader
_x86_start_after_loader:
    /* Common path joined by:
     *   - start_kernel_asm_entry above (fall-through)
     *   - the eventual EFI direct-boot path (jmp from efi_stub.S)
     *
     * Hand off to the Hamnix kernel. SysV AMD64: no args, no return
     * value. start_kernel() walks the boot info (multiboot mmap via
     * mb_info, or — in a future commit — the EFI memory map saved by
     * efi_stub.S) and brings every subsystem up. */
    call    start_kernel

    /* If start_kernel returns (it shouldn't yet), halt forever. */
halt_loop:
    cli
    hlt
    jmp     halt_loop

/* ---------- kernel_image_end() ----------------------------------- *
 * Returns the physical address one past the last byte the kernel
 * image occupies (= __bss_end). The kernel is identity-mapped, so
 * VMA == LMA == physical. mm/memblock callers bump their pool's base
 * past this so freshly-allocated pages can't overlap kernel
 * .text / .rodata / .data / .pgtables / .bss.
 *
 * Same trick as arch/x86/kernel/smp_asm.S's accessors: the linker
 * symbol is an absolute value, so we stash it as a 32-bit word in
 * .rodata and load via leaq + movl. That sidesteps the ELF32 R_X86_64
 * relocation gap our elf32-i386 OUTPUT_FORMAT can't represent.
 */
    .section .rodata
    .align 4
__bss_end_word:
    .long __bss_end

    .section .text, "ax"
    .align 16
    .globl kernel_image_end
kernel_image_end:
    leaq    __bss_end_word(%rip), %rax
    movl    (%rax), %eax
    ret
