/*
 * arch/x86/kernel/kernel.lds - Hamnix bare-metal x86_64 kernel linker script.
 *
 * HIGHER-HALF KERNEL: the kernel proper is LINKED at the canonical
 * x86_64 kernel virtual base 0xffffffff80000000 (PML4 entry 511, the
 * top 2 GiB) but LOADED at low physical addresses (1 MiB and up). The
 * VMA-vs-LMA split is expressed with `AT(...)` on the high-half output
 * sections.
 *
 * WHY higher-half:
 *   A non-PIE ET_EXEC Linux binary links at 0x400000; its brk heap and
 *   mmap regions extend upward from there. With the old identity-mapped
 *   low-half kernel that collided with the kernel image. Vacating the
 *   entire lower canonical half for userland is what lets ordinary
 *   ET_EXEC binaries load and run.
 *
 * BOOT FORMAT — true 64-bit ELF:
 *   This produces an `elf64-x86-64` ELF. The old elf32-i386 wrapper
 *   could not represent symbol addresses above 4 GiB (R_386_32 is a
 *   32-bit absolute relocation); the higher-half base needs 64-bit
 *   absolutes (R_X86_64_64) for the IDT/IRQ stub tables and a handful
 *   of linker-symbol address words.
 *
 *   The kernel is booted by GRUB's multiboot1 loader (BIOS path, via
 *   the hybrid ISO) and by the native PE/COFF stub (UEFI path,
 *   arch/x86/boot/efi_stub.S). Both accept ELFCLASS64 and load PT_LOAD
 *   segments by p_paddr (a 64-bit field), so the VMA/LMA split rides
 *   cleanly. QEMU's built-in `-kernel` multiboot1 loader does NOT
 *   accept 64-bit ELFs — the test harness therefore wraps the kernel
 *   in a minimal BIOS GRUB ISO (scripts/_kernel_iso.sh) and boots it
 *   with `-cdrom` instead of `-kernel`.
 *
 *   Multiboot1 hands control off in 32-bit protected mode at the ELF
 *   e_entry. e_entry is `_start` (arch/x86/boot/header.S), a LOW
 *   (32-bit-addressable) address in the .head.text section. The 32-bit
 *   boot stub builds page tables mapping the kernel image at BOTH the
 *   low identity address AND the high half, enters long mode, and
 *   far-jumps to the high virtual address.
 *
 * SECTION REGIONS:
 *   1. LOW boot region @ 0x100000 (VMA == LMA):
 *        .head.text   multiboot header + 32-bit _start stub
 *        .boot.text   64-bit long_mode_start trampoline tail + the low
 *                     UEFI entry shim (reachable at the low identity
 *                     address right after the far-jump-into-long-mode)
 *        .boot.data   mb_magic / mb_info / boot_via_efi / gdt64 /
 *                     efi_fb_info — referenced with 32-bit-form refs.
 *        .pgtables    NOBITS page tables, referenced by CR3.
 *        .boot.bss    boot stack.
 *   2. HIGH-half region @ 0xffffffff80000000 + offset (VMA != LMA;
 *      LMA continues right after the low region via AT(...)):
 *        .text .rodata .data..percpu .data
 *        .ap_trampoline (its own VMA=0x8000 sub-split, LMA inside img)
 *        .bss
 */

OUTPUT_FORMAT("elf64-x86-64")
OUTPUT_ARCH(i386:x86-64)
ENTRY(_start)

/* Canonical x86_64 higher-half kernel base: PML4 entry 511, top 2 GiB. */
KERNEL_VBASE = 0xffffffff80000000;

SECTIONS
{
    /* ---- LOW boot region: VMA == LMA, multiboot 1 MiB minimum. ----
     * Everything the 32-bit (paging-off / identity-mapped) boot stub
     * touches lives here at a low, 32-bit-addressable address. The ELF
     * e_entry (_start) is in .head.text so GRUB's multiboot1 handoff —
     * which jumps to e_entry in 32-bit protected mode — lands on real
     * 32-bit code at a real low physical address. */
    . = 0x100000;
    __low_start = .;

    /* .head.text holds the multiboot header + 32-bit boot stub. First
     * so the multiboot magic lands within the first 8 KiB of the
     * file (the boot loader scan window). */
    .head.text : {
        *(.head.text)
    }

    /* .boot.text: the 64-bit long-mode trampoline tail + the low UEFI
     * entry shim. Still fetched at the LOW identity address in the
     * brief window between enabling paging and the far-jump that
     * re-anchors RIP into the high half. */
    .boot.text : ALIGN(16) {
        *(.boot.text)
    }

    /* .boot.data: gdt64 / mb_magic / mb_info / boot_via_efi /
     * efi_fb_info — boot-time globals the 32-bit stub and the EFI
     * handoff table reference with 32-bit-form references. */
    .boot.data : ALIGN(16) {
        *(.boot.data)
    }

    /* Page tables: NOBITS the loader zero-fills; the boot-time
     * BSS-zero loop must NOT touch it (CR3 roots it). Pinned LMA == VMA
     * (it is in the low VMA==LMA region) so grub2 and the EFI loader
     * place the zero-fill region exactly where _start writes to it.
     * Lives outside [__bss_start,__bss_end). */
    .pgtables (NOLOAD) : ALIGN(4096) {
        *(.pgtables)
    }

    /* Boot stack: used only via %esp/%rsp by the 32-bit stub and the
     * long-mode trampoline tail before start_kernel switches stacks. */
    .boot.bss (NOLOAD) : ALIGN(4096) {
        *(.boot.bss)
    }
    __low_end = .;

    /* ---- HIGH-half region: VMA at KERNEL_VBASE+offset, LMA low. ----
     * The bulk of the kernel, linked at the high virtual base; LMA
     * continues immediately after the low boot region so the loader
     * packs the whole image contiguously. kernel_lma tracks the
     * running load (physical) cursor; every high-half output section
     * uses AT(kernel_lma + (VMA - __high_vbase)) so p_paddr stays low
     * while p_vaddr is high. */
    kernel_lma = __low_end;
    . = KERNEL_VBASE + __low_end;
    __high_vbase = .;

    .text : AT(kernel_lma + (ADDR(.text) - __high_vbase)) ALIGN(16) {
        __kernel_text_start = .;
        *(.text)
        *(.text.*)
    }

    .rodata : AT(kernel_lma + (ADDR(.rodata) - __high_vbase)) ALIGN(16) {
        *(.rodata)
        *(.rodata.*)
        *(.rdata)
        *(.rdata.*)
    }

    /* Per-CPU template — see codegen_x86.py. Access sites emit
     * %gs:offset with a literal displacement, so this section's own
     * VMA/LMA can be anywhere. */
    .data..percpu : AT(kernel_lma + (ADDR(.data..percpu) - __high_vbase)) ALIGN(8) {
        *(.data..percpu)
    }

    .data : AT(kernel_lma + (ADDR(.data) - __high_vbase)) ALIGN(16) {
        *(.data)
        *(.data.*)
    }

    /* AP boot trampoline. VMA = 0x8000 because SIPI delivers the AP to
     * physical 0x8000; the linker resolves intra-section references
     * against 0x8000. LMA rides inside the kernel image; the BSP
     * memcpys the bytes from LMA to 0x8000 before SIPI. */
    __ap_trampoline_load = kernel_lma + (. - __high_vbase);
    .ap_trampoline 0x8000 : AT(__ap_trampoline_load) {
        __ap_trampoline_start = .;
        KEEP(*(.ap_trampoline))
        __ap_trampoline_end = .;
    }
    __ap_trampoline_size = __ap_trampoline_end - __ap_trampoline_start;
    /* Resume the high-half VMA cursor past the trampoline bytes. */
    . = __high_vbase + (__ap_trampoline_load - kernel_lma) + __ap_trampoline_size;

    /* BSS — zeroed by head_64.S via __bss_start/__bss_end. NOBITS (no
     * file bytes). An explicit AT() pins p_paddr LOW: without it the
     * linker defaults a NOBITS segment's p_paddr to its (high) VMA,
     * and a multiboot1 loader that zero-fills NOBITS PT_LOAD segments
     * by p_paddr would target an address above 4 GiB. Pinning the LMA
     * into the contiguous low image keeps the zero-fill region inside
     * real low RAM — and is also what kernel_image_end()'s
     * `__bss_end - KERNEL_VBASE` arithmetic assumes. Both ends aligned
     * to 8 for a clean `rep stosq`. */
    .bss (NOLOAD) : AT(kernel_lma + (ADDR(.bss) - __high_vbase)) ALIGN(4096) {
        __bss_start = .;
        *(.bss)
        *(.bss.*)
        *(COMMON)
        . = ALIGN(8);
        __bss_end = .;
    }
    __kernel_text_end = .;

    /DISCARD/ : {
        *(.note.*)
        *(.comment)
        *(.eh_frame)
        *(.eh_frame_hdr)
        *(.dynamic)
        *(.dynsym)
        *(.dynstr)
        *(.hash)
        *(.gnu.hash)
        *(.interp)
    }
}
