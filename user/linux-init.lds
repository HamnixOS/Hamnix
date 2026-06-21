/*
 * user/linux-init.lds — linker script for the `x86_64-linux` freestanding
 * Adder target.
 *
 * Emits a plain static elf64-x86-64 executable the HOST Linux kernel loads
 * directly: a single read+exec PT_LOAD covering .text/.rodata, then a
 * writable PT_LOAD for .data/.bss. Entry is _start (user/linux-runtime.S).
 *
 * Unlike the Hamnix user/init.lds this does NOT use the elf32-i386 wrapper
 * + `.code64` trick (that exists only because the Hamnix in-kernel ELF
 * loader parses elf32 headers). A real Linux loader wants a genuine
 * elf64-x86-64 image, so we output one straight.
 *
 * Load base 0x400000 is the conventional non-PIE x86_64 text address; a
 * static -no-pie executable maps there with no relocations needed.
 */

OUTPUT_FORMAT("elf64-x86-64")
OUTPUT_ARCH(i386:x86-64)
ENTRY(_start)

PHDRS {
    text PT_LOAD FLAGS(5);   /* R + X */
    data PT_LOAD FLAGS(6);   /* R + W */
}

SECTIONS
{
    . = 0x400000;

    .text : ALIGN(0x1000) {
        *(.text)
        *(.text.*)
    } : text

    .rodata : ALIGN(0x10) {
        *(.rodata)
        *(.rodata.*)
    } : text

    . = ALIGN(0x1000);

    .data : ALIGN(0x10) {
        *(.data)
        *(.data.*)
    } : data

    .bss : ALIGN(0x10) {
        *(.bss)
        *(.bss.*)
        *(COMMON)
    } : data

    /DISCARD/ : {
        *(.note.*)
        *(.comment)
        *(.eh_frame)
        *(.eh_frame_hdr)
    }
}
