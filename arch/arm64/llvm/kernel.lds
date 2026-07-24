/*
 * arch/arm64/llvm/kernel.lds — image layout for the LLVM whole-kernel aarch64
 * boot lane (docs/arm64_llvm_scoping.md A3; scripts/build_kernel_llvm_arm64.sh).
 *
 * QEMU `-M virt -kernel <img>` loads at physical 0x4008_0000 and enters at the
 * first byte. We link identity (VMA == LMA == PA): the head.S MMU sets up a
 * 1:1 identity map, so no VMA/LMA split is needed for A3. (The x86 lane links
 * higher-half at 0xffffffff80000000; the aarch64 high-half TTBR1 kernel VA is a
 * later phase — the emitter bakes no absolute kernel VA into the IR, so this is
 * purely a linker-script/MMU concern, per the scoping doc §2c.)
 *
 * Section order: .boot.text (reset entry _start) FIRST so it lands at the
 * 0x4008_0000 entry; then the 0x800-aligned vector table, .text (the emitted
 * LLVM kernel + intrinsics + stubs), .rodata, .data, .bss. The boot stack is
 * pinned high in the identity-mapped RAM block (0x4000_0000-0x7FFF_FFFF), well
 * clear of the image, so image growth can never collide with the C stack.
 */

OUTPUT_FORMAT("elf64-littleaarch64")
OUTPUT_ARCH(aarch64)
ENTRY(_start)

KERNEL_LOAD  = 0x40080000;   /* QEMU virt -kernel load/entry PA */
STACK_TOP    = 0x60000000;   /* 512 MiB into RAM (inside the 1 GiB identity block) */

SECTIONS
{
    . = KERNEL_LOAD;

    .boot.text : {
        KEEP(*(.boot.text))
    }

    .text : ALIGN(0x800) {
        KEEP(*(.text.vectors))
        *(.text .text.*)
    }

    .rodata : ALIGN(16) {
        *(.rodata .rodata.*)
        *(.rdata .rdata.*)
    }

    .data : ALIGN(16) {
        *(.data .data.*)
    }

    /* Keep any GOT/PLT the aarch64 code model materialises (must not be
     * DISCARDed: ld errors "discarded output section: .got.plt" if it has
     * content). With -static -no-pie these are normally tiny/empty. */
    .got  : ALIGN(8) { *(.got) *(.got.plt) }
    .plt  : ALIGN(16) { *(.plt) *(.iplt) }
    .rela.dyn : { *(.rela.dyn) *(.rela.plt) }

    .bss (NOLOAD) : ALIGN(16) {
        __bss_start = .;
        *(.bss .bss.*)
        *(COMMON)
        . = ALIGN(8);
        __bss_end = .;
    }

    __stack_top = STACK_TOP;

    /DISCARD/ : {
        *(.comment)
        *(.note .note.*)
        *(.eh_frame .eh_frame_hdr)
        *(.dynamic) *(.dynsym) *(.dynstr) *(.hash) *(.gnu.hash) *(.interp)
        *(.ARM.exidx*) *(.ARM.attributes)
    }
}
