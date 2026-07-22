/*
 * user/linux-init-pie.lds — PIE (ET_DYN) linker script for the
 * `x86_64-linux` freestanding Adder target, used specifically for the
 * self-hosted host compiler (host_ac.elf).
 *
 * This is the position-independent sibling of user/linux-init.lds. It emits
 * an elf64-x86-64 ET_DYN image based at vaddr 0 (fully relative). The
 * compiler-emitted code is already position-independent — every global is
 * reached RIP-relative (`lea g(%rip)`) and there are NO absolute data
 * pointers, so linking `-pie` produces ZERO dynamic relocations (verified
 * with `readelf -r`). Because there are no relocations to apply, the image
 * runs correctly at ANY load base with no relocator: neither the host Linux
 * kernel (which maps the PIE at a random base) nor the Hamnix ET_DYN loader
 * (fs/elf.ad, which rebases to a high dyn_vbase >= 4 GiB via aslr_load_bias)
 * needs to touch it. `_start` (user/linux-runtime.S) is likewise PIC.
 *
 * WHY PIE for host_ac: as ET_EXEC at the conventional low base 0x400000 the
 * ~474 MiB writable/BSS PT_LOAD lands at ~0x488000 and spans into the kernel's
 * low-identity direct map, aliasing virtqueue rings / kstacks / slab / page
 * tables on-device. As ET_DYN the loader places the whole image (BSS included)
 * at a HIGH vaddr above physical RAM, sidestepping that entire collision class.
 *
 * The regular ET_EXEC low-base path (user/linux-init.lds) is UNCHANGED and
 * still used by every other x86_64-linux consumer.
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
    . = 0;

    /* ELF header + program headers live in the first read-exec page so the
     * PT_LOAD covering vaddr 0 is well-formed for a relative image. */
    .text : ALIGN(0x1000) {
        *(.text)
        *(.text.*)
    } : text

    .rodata : ALIGN(0x10) {
        *(.rodata)
        *(.rodata.*)
    } : text

    /* PIE metadata the linker synthesizes (empty in practice — no relocs,
     * no dynamic symbols beyond the null entry — but map them read-only so
     * any that appear stay in the text segment). */
    .dynsym    : { *(.dynsym) }    : text
    .dynstr    : { *(.dynstr) }    : text
    .gnu.hash  : { *(.gnu.hash) }  : text
    .hash      : { *(.hash) }      : text
    .rela.dyn  : { *(.rela.dyn) }  : text

    . = ALIGN(0x1000);

    .dynamic : { *(.dynamic) } : data

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
        *(.interp)
    }
}
