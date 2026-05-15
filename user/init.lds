/*
 * user/init.lds - linker script for the standalone user-mode /init.
 *
 * Output is elf32-i386 (matches the kernel's wrapper format; the
 * Pynux ELF loader doesn't currently parse elf64). Single PT_LOAD
 * segment containing .text + .rodata + the read buffer, starting at
 * virtual address 0. Position-independent code (all RIP-relative)
 * means the kernel can rebase to whatever physical page it allocates.
 */

OUTPUT_FORMAT("elf32-i386")
OUTPUT_ARCH(i386)
ENTRY(_start)

PHDRS {
    text PT_LOAD;
}

SECTIONS
{
    . = 0;

    .text : ALIGN(16) {
        *(.text)
        *(.text.*)
        *(.rodata)
        *(.rodata.*)
    } : text

    /DISCARD/ : {
        *(.note.*)
        *(.comment)
        *(.eh_frame)
        *(.eh_frame_hdr)
    }
}
