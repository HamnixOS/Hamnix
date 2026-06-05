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
 *   .data/.bss  — globals; .bss is zeroed implicitly by being NOBITS.
 *
 * Boot stack placement: the stack must NOT be placed immediately after .bss.
 * The kernel grows its image upward from KERNEL_LOAD (0x4008_0000) toward the
 * fixed scratch/page-table region at 0x4010_0000.. (L1/L2 page tables + the
 * per-phase EL0 task CONTEXT blocks at 0x4010_4000+). If the boot stack rode
 * directly on top of .bss, a large enough kernel image would push __stack_top
 * past 0x4010_0000, and the kernel's C-stack would then silently overwrite the
 * live page tables and EL0 task context blocks — corrupting e.g. TASK1_CTX's
 * saved SPSR and triggering an Illegal-Execution-State (EC=0x0E) abort on the
 * next ERET. To make the boot stack independent of image size, we PIN it to a
 * fixed high address in identity-mapped RAM (the MMU 1 GiB-blocks all of
 * 0x4000_0000..0x7FFF_FFFF), far above every scratch region the phases use.
 */

OUTPUT_FORMAT("elf64-littleaarch64")
OUTPUT_ARCH(aarch64)
ENTRY(_start)

/* QEMU virt -kernel load/entry address. */
KERNEL_LOAD = 0x40080000;

/* Boot stack size (64 KiB is plenty for the banner-print stub). */
STACK_SIZE = 0x10000;

/*
 * Fixed boot-stack TOP, pinned in identity-mapped RAM well clear of both the
 * kernel image (grows up from 0x4008_0000) and every phase scratch region
 * (page tables + EL0 contexts at 0x4010_0000.., EL0 windows + private PA trees
 * up to ~0x4B20_0000). QEMU `virt` gives us 256 MiB (0x4000_0000..0x5000_0000),
 * so 0x4FF0_0000 leaves a 1 MiB guard below the top of RAM and ~75 MiB of clear
 * space above the highest scratch address any phase touches.
 */
STACK_TOP_FIXED = 0x4FF00000;

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

    /*
     * Boot stack: pinned to a fixed high address (STACK_TOP_FIXED) so it is
     * INDEPENDENT of the kernel image size. Growing the image can therefore
     * never push the C-stack into the page tables / EL0 context region.
     */
    __stack_top = STACK_TOP_FIXED;
    __stack_bottom = STACK_TOP_FIXED - STACK_SIZE;

    /DISCARD/ : {
        *(.comment)
        *(.note .note.*)
        *(.eh_frame .eh_frame_hdr)
    }
}
