/*
 * arch/arm64/kernel.lds — Phase 2 bare-metal aarch64 kernel image layout.
 *
 * QEMU's `virt` machine loads a `-kernel` image at physical 0x4008_0000 and
 * enters at the image's first byte. We link at that same address so the
 * load address == the link address (the MMU is off, so VMA == LMA == PA)
 * and `_start` from arch/arm64/boot.S sits at the entry point.
 *
 * Section order:
 *   .boot.text  — the reset entry (_start). MUST be first.
 *   .text       — the Adder-compiled kmain and friends.
 *   .rodata     — string literals (the UART banner).
 *   .data/.bss  — globals; .bss is zeroed implicitly by being NOBITS, but
 *                 this stub allocates the boot stack right after it.
 */

OUTPUT_FORMAT("elf64-littleaarch64")
OUTPUT_ARCH(aarch64)
ENTRY(_start)

/* QEMU virt -kernel load/entry address. */
KERNEL_LOAD = 0x40080000;

/* Boot stack size (64 KiB is plenty for the banner-print stub). */
STACK_SIZE = 0x10000;

SECTIONS
{
    . = KERNEL_LOAD;

    .boot.text : {
        KEEP(*(.boot.text))
    }

    .text : {
        *(.text .text.*)
    }

    .rodata : {
        *(.rodata .rodata.*)
    }

    .data : {
        *(.data .data.*)
    }

    .bss : {
        __bss_start = .;
        *(.bss .bss.*)
        *(COMMON)
        __bss_end = .;
    }

    /* Boot stack: reserve STACK_SIZE bytes; the top is the initial SP. */
    . = ALIGN(16);
    __stack_bottom = .;
    . = . + STACK_SIZE;
    . = ALIGN(16);
    __stack_top = .;

    /DISCARD/ : {
        *(.comment)
        *(.note .note.*)
        *(.eh_frame .eh_frame_hdr)
    }
}
