/*
 * arch/x86/kernel/vmlinux.lds - Hamnix bare-metal x86_64 kernel linker script.
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

    /* Main kernel text: head_64.S + every Hamnix-emitted .text section. */
    .text : ALIGN(16) {
        *(.text)
        *(.text.*)
    }

    .rodata : ALIGN(16) {
        *(.rodata)
        *(.rodata.*)
    }

    /* Per-CPU template lives in a dedicated section just before .data.
     * The codegen places each Percpu[T] global at a compile-time-known
     * BYTE OFFSET into this section (tracked in self.percpu_offsets) and
     * emits `%gs:offset, %rax` directly with a literal displacement —
     * no symbol relocation, so we sidestep the elf32-i386 / 64-bit
     * absolute-relocation incompatibility entirely. The section's own
     * VMA/LMA can be wherever the linker wants; we just need the bytes
     * loaded somewhere we can memcpy() out at boot. The codegen also
     * emits __per_cpu_template_start / __per_cpu_template_end markers
     * around the contents. */
    .data..percpu : ALIGN(8) {
        *(.data..percpu)
    }

    .data : ALIGN(16) {
        *(.data)
        *(.data.*)
    }

    /* AP boot trampoline. VMA = 0x8000 because SIPI delivers the AP
     * to physical 0x8000 (vector 0x08 × 0x1000); the linker resolves
     * all symbol references within the section against that address.
     * LMA is the current load cursor — the bytes ride along in the
     * kernel image at whatever address that resolves to; the BSP
     * memcpys them from LMA to VMA before sending SIPI. Mirrors the
     * same VMA/LMA-split trick Hamnix already uses for .data..percpu. */
    __ap_trampoline_load = .;
    .ap_trampoline 0x8000 : AT(__ap_trampoline_load) {
        __ap_trampoline_start = .;
        KEEP(*(.ap_trampoline))
        __ap_trampoline_end = .;
    }
    __ap_trampoline_size = __ap_trampoline_end - __ap_trampoline_start;
    . = __ap_trampoline_load + __ap_trampoline_size;

    /* Page tables: NOBITS section that the loader zero-fills at load
     * time but the boot-time BSS-zero loop must NOT touch — pml4/pdpt/pd
     * are referenced by CR3 the moment the kernel enters long mode. Live
     * in their own section explicitly *outside* [__bss_start, __bss_end).
     *
     * AT(ADDR(.pgtables)) pins the LMA to match the VMA. QEMU's `-kernel`
     * multiboot1 loader was lenient about this — it placed NOBITS bytes
     * at the VMA — but real loaders (grub-mkrescue/grub2) strictly honour
     * the program-header PhysAddr. Without AT(), ld emits PhysAddr ≠
     * VirtAddr for this BSS-style PT_LOAD, which makes grub allocate the
     * zero-fill region at a different physical address than the kernel
     * writes to in _start. Result: page-table writes land outside the
     * allocated region and the first instruction fetch under paging
     * triple-faults. Pinning LMA = VMA closes the gap for both loaders. */
    .pgtables (NOLOAD) : AT(ADDR(.pgtables)) ALIGN(4096) {
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
