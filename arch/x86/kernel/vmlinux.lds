/*
 * arch/x86/kernel/vmlinux.lds - Pynux bare-metal x86_64 kernel linker script.
 *
 * Mirrors arch/x86/kernel/vmlinux.lds.S (Linux). The kernel is loaded at
 * the standard multiboot 1 MiB physical address; for M16.1 we identity-map
 * the first 1 GiB so the link-time VMA == LMA. When we introduce a higher-
 * half kernel mapping later, we'll add `AT(...)` directives to split VMA
 * from LMA. For now, plain linking suffices.
 */

/*
 * NOTE: This produces an `elf32-i386` ELF even though the bulk of .text is
 * 64-bit instructions. QEMU's `-kernel` multiboot1 loader requires
 * ELFCLASS32, but `.code64` directives in the .S sources tell the
 * assembler to emit 64-bit instruction encodings inside an elf32-i386
 * object. The relocations we use (R_386_PC32 for RIP-relative + R_386_32
 * for absolute) all fit in 32-bit form, so the link succeeds. When we
 * later switch to a higher-half mapping above 4 GiB, we'll need a true
 * 64-bit ELF and a different boot protocol.
 */
OUTPUT_FORMAT("elf32-i386")
OUTPUT_ARCH(i386)
ENTRY(_start)

SECTIONS
{
    /* Multiboot 1 mandates 1 MiB minimum load address; QEMU's -kernel
     * loader also expects ELF loadable headers, which this script emits. */
    . = 0x100000;

    /* .head.text holds the multiboot header + 32-bit boot stub. Placed
     * first so the multiboot magic lands within the first 8 KiB of the
     * file (the boot loader scan window). */
    .head.text : {
        *(.head.text)
    }

    /* Main kernel text: head_64.S + every Pynux-emitted .text section. */
    .text : ALIGN(16) {
        *(.text)
        *(.text.*)
    }

    .rodata : ALIGN(16) {
        *(.rodata)
        *(.rodata.*)
    }

    .data : ALIGN(16) {
        *(.data)
        *(.data.*)
    }

    /* Page tables: NOBITS section that the loader zero-fills at load
     * time but the boot-time BSS-zero loop must NOT touch — pml4/pdpt/pd
     * are referenced by CR3 the moment the kernel enters long mode. Live
     * in their own section explicitly *outside* [__bss_start, __bss_end). */
    .pgtables (NOLOAD) : ALIGN(4096) {
        *(.pgtables)
    }

    /* BSS gets zeroed by head_64.S using __bss_start/__bss_end. Align both
     * ends to 8 so a `rep stosq` clears the full region without overrun. */
    .bss : ALIGN(4096) {
        __bss_start = .;
        *(.bss)
        *(.bss.*)
        *(COMMON)
        . = ALIGN(8);
        __bss_end = .;
    }

    /DISCARD/ : {
        *(.note.*)
        *(.comment)
        *(.eh_frame)
        *(.eh_frame_hdr)
    }
}
