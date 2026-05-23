/*
 * arch/x86/boot/header.S - Hamnix multiboot1 entry + 32->64 long-mode
 *                          transition into a HIGHER-HALF kernel.
 *
 * Mirrors the role of Linux's arch/x86/boot/header.S (boot protocol
 * header) and arch/x86/boot/compressed/head_64.S (long-mode setup),
 * collapsed into one file for the simpler multiboot1 path.
 *
 * Control flow on a QEMU `-kernel` / GRUB multiboot1 boot:
 *   1. The loader acts as a multiboot1 loader. It locates the magic
 *      header below, loads the (elf64-x86-64) ELF's PT_LOAD segments
 *      by their p_paddr (LOW physical addresses), and jumps to the ELF
 *      e_entry = `_start` (this file, .head.text) in 32-bit protected
 *      mode with paging off, EAX=0x2BADB002, EBX=&multiboot_info.
 *   2. _start runs at a LOW physical/virtual address (identity). It
 *      builds 4-level page tables that map the kernel image TWICE:
 *        - PML4[0]   -> low identity (so this in-flight 32-bit code,
 *                       the page tables, the boot stack, and physical
 *                       RAM all stay reachable), and
 *        - PML4[511] -> the higher half 0xffffffff80000000, where the
 *                       kernel proper is LINKED.
 *      It enables PAE + EFER.LME + CR0.PG, then far-jumps through the
 *      64-bit GDT to `long_mode_start` (also low / identity — the
 *      far-jump just flushes CS into 64-bit mode).
 *   3. long_mode_start re-anchors the stack and does an absolute
 *      indirect jump to the HIGH-half virtual address of
 *      start_kernel_asm_entry (arch/x86/kernel/head_64.S). From that
 *      point on RIP runs in the higher half and every kernel symbol
 *      resolves to its 0xffffffff80000000+offset link-time VMA.
 *
 * The low identity map of PML4[0] is intentionally KEPT after the
 * transition: the kernel still needs to touch physical RAM directly
 * (page allocator, e820 walk, AP trampoline at 0x8000, framebuffer).
 * Only the kernel-image-runs-low assumption is gone.
 *
 * Everything here is hand-written GNU `as` AT&T syntax. The whole
 * kernel is now assembled with `as --64` and linked `ld -m elf_x86_64`
 * (a true 64-bit ELF), so 64-bit absolute relocations (R_X86_64_64)
 * for the higher-half symbols are representable.
 */

    .section .head.text, "ax"
    .code32

/* ---------- Multiboot1 header (must live in first 8 KiB of ELF) ----- *
 *
 * Flag bits:
 *   bit 0 (0x00000001) MULTIBOOT_PAGE_ALIGN    — modules page-aligned
 *   bit 1 (0x00000002) MULTIBOOT_MEMORY_INFO   — request mem_lower/upper
 *   bit 2 (0x00000004) MULTIBOOT_VIDEO_MODE    — request a video mode
 *   bit 16 (0x00010000) MULTIBOOT_AOUT_KLUDGE  — use header_addr fields
 *
 * Only bit 2 is set: request a linear framebuffer (mode_type=0). Bit
 * 16 (AOUT kludge) is deliberately NOT set — the kernel is a true
 * elf64 ELF and the loaders that consume it (GRUB's multiboot1 ELF
 * loader on the BIOS-via-ISO path, the native PE/COFF stub on the
 * UEFI path) both handle ELFCLASS64 and the program-header VMA/LMA
 * split natively. QEMU's built-in `-kernel` loader rejects 64-bit
 * ELFs, so the test harness boots the kernel from a BIOS GRUB ISO
 * (scripts/_kernel_iso.sh) rather than via `-kernel`.
 *
 * Layout — fields at spec-mandated fixed offsets even when the gating
 * flag bit isn't set (the loader walks by offset):
 *   off  0 magic / 4 flags / 8 checksum
 *   off 12..28 header_addr..entry_addr (unused, bit 16 clear)
 *   off 32..44 mode_type/width/height/depth (video request)
 */
    .equ    MB_MAGIC,    0x1BADB002
    .equ    MB_FLAGS,    0x00000004        /* VIDEO_MODE */
    .equ    MB_CHECKSUM, -(MB_MAGIC + MB_FLAGS)

    /* Hamnix EFI handoff table magic ("HAMX" little-endian). */
    .equ    HAMNIX_HANDOFF_MAGIC, 0x484D4158

    .align 4
multiboot_header:
    .long   MB_MAGIC                /* off  0 */
    .long   MB_FLAGS                /* off  4 */
    .long   MB_CHECKSUM             /* off  8 */
    .long   0x00000000              /* off 12 header_addr   */
    .long   0x00000000              /* off 16 load_addr     */
    .long   0x00000000              /* off 20 load_end_addr */
    .long   0x00000000              /* off 24 bss_end_addr  */
    .long   0x00000000              /* off 28 entry_addr    */
    .long   0x00000000              /* off 32 mode_type = 0 (linear FB) */
    .long   0x00000000              /* off 36 width  = any              */
    .long   0x00000000              /* off 40 height = any              */
    .long   0x00000000              /* off 44 depth  = any              */

    /* ---- Hamnix EFI handoff table (fixed offset 48) -----------------
     *
     *   +48  uint32  HAMNIX_HANDOFF_MAGIC ("HAMX")
     *   +52  uint32  efi_entry_addr     = &_x86_start_after_loader
     *   +56  uint32  boot_via_efi_addr  = &boot_via_efi
     *   +60  uint32  gdt64_addr         = &gdt64
     *   +64  uint32  efi_fb_info_addr   = &efi_fb_info  (GOP capture)
     *   +68  uint32  efi_mmap_info_addr = &efi_mmap_info (EFI memmap)
     *
     * EVERY symbol referenced here lives in the LOW boot region
     * (.head.text / .boot.text / .boot.data), so each .long resolves
     * to a real 32-bit address even though the kernel proper is now
     * linked in the higher half. The EFI stub patches/reads these by
     * their LOW physical address (= LMA = VMA for the boot region).
     *
     * Slot +68 (efi_mmap_info_addr) is the M16.155 "unlock RAM > 240 MiB
     * on UEFI" wiring: the stub stashes a pointer + size for the
     * EFI_MEMORY_DESCRIPTOR array it captured via GetMemoryMap right
     * before ExitBootServices. e820_init() in arch/x86/kernel/e820.ad
     * walks the descriptors to pick the largest free-RAM region — same
     * shape as the multiboot1-mmap path, but driven by firmware truth
     * rather than the conservative 2..240 MiB fallback.
     */
    .long   HAMNIX_HANDOFF_MAGIC    /* off 48 */
    .long   _x86_start_after_loader /* off 52 */
    .long   boot_via_efi            /* off 56 */
    .long   gdt64                   /* off 60 */
    .long   efi_fb_info             /* off 64 */
    .long   efi_mmap_info           /* off 68 */

/* ---------- 32-bit protected-mode entry ---------------------------- */
    .globl  _start
_start:
    cli
    /* Tiny 32-bit stack in the low boot region. */
    movl    $boot_stack_top, %esp

    /* Stash multiboot magic + info ptr. */
    movl    %eax, mb_magic
    movl    %ebx, mb_info

    /* Verify we were booted by a multiboot loader. */
    cmpl    $0x2BADB002, %eax
    jne     hang32

    /* ----- Build 4-level page tables -------------------------------- *
     * Layout:
     *   PML4[0]   -> pdpt_low   : 4 GiB low identity (PS=1, 4× 1 GiB)
     *   PML4[511] -> pdpt_high  : the higher half. Within pdpt_high,
     *                entry 510 maps 0xffffffff80000000 and entry 511
     *                maps 0xffffffffc0000000, both to physical 0 / 1
     *                GiB via PS=1 1 GiB pages. That makes the kernel's
     *                link-time VMA 0xffffffff80000000+offset resolve
     *                to physical 0+offset — exactly the LMA the loader
     *                packed the high-half PT_LOAD segments into.
     *
     * PML4 index math for 0xffffffff80000000:
     *   bits[47:39] = 0x1FF (511)  -> PML4[511]
     *   bits[38:30] = 0x1FE (510)  -> pdpt_high[510]
     * and 0xffffffffc0000000 -> PML4[511], pdpt_high[511].
     */

    /* PML4[0] -> pdpt_low */
    movl    $pml4, %edi
    movl    $pdpt_low, %eax
    orl     $0x7, %eax              /* US | RW | P */
    movl    %eax, (%edi)
    movl    $0, 4(%edi)

    /* PML4[511] -> pdpt_high. Slot 511 is at byte offset 511*8 = 0xFF8. */
    movl    $pml4, %edi
    addl    $0xFF8, %edi
    movl    $pdpt_high, %eax
    orl     $0x7, %eax              /* US | RW | P */
    movl    %eax, (%edi)
    movl    $0, 4(%edi)

    /* pdpt_low: 4 entries, each a 1 GiB identity page (PS=1).
     *   bit 0 P, bit 1 RW, bit 2 US, bit 7 PS (1 GiB terminal). */
    movl    $pdpt_low, %edi
    movl    $0, %ecx
    movl    $0x87, %eax             /* PS | US | RW | P; phys base = 0 */
1:
    movl    %eax, (%edi)
    movl    $0, 4(%edi)
    addl    $0x40000000, %eax       /* next 1 GiB */
    addl    $8, %edi
    incl    %ecx
    cmpl    $4, %ecx
    jne     1b

    /* pdpt_high[510] -> 1 GiB page @ phys 0   (0xffffffff80000000)
     * pdpt_high[511] -> 1 GiB page @ phys 1 G (0xffffffffc0000000)
     * Kernel-only (US=0) is correct for the higher half, but we keep
     * US=1 to exactly mirror pdpt_low — the per-task PML4 clone in
     * kernel/sched/core.ad copies PML4[511] verbatim, and US-bit
     * uniformity sidesteps any walk-time surprises. */
    movl    $pdpt_high, %edi
    addl    $(510 * 8), %edi
    movl    $0x87, %eax             /* PS|US|RW|P, phys 0 */
    movl    %eax, (%edi)
    movl    $0, 4(%edi)
    movl    $0x40000087, %eax       /* PS|US|RW|P, phys 0x40000000 */
    movl    %eax, 8(%edi)
    movl    $0, 12(%edi)

    /* ----- Enable PAE, load CR3, set EFER.LME, then CR0.PG ---------- */
    movl    %cr4, %eax
    orl     $(1 << 5), %eax         /* CR4.PAE */
    /* SSE/SSE2 hardware: OSFXSR (bit 9) + OSXMMEXCPT (bit 10). */
    orl     $(1 << 9) | (1 << 10), %eax
    movl    %eax, %cr4

    movl    $pml4, %eax
    movl    %eax, %cr3

    movl    $0xC0000080, %ecx       /* IA32_EFER */
    rdmsr
    orl     $(1 << 8), %eax         /* EFER.LME */
    wrmsr

    movl    %cr0, %eax
    orl     $(1 << 31), %eax        /* CR0.PG  - paging on, enter IA-32e */
    orl     $(1 << 1), %eax         /* CR0.MP */
    andl    $~((1 << 2) | (1 << 3)), %eax  /* clear CR0.EM, CR0.TS */
    movl    %eax, %cr0

    /* Load 64-bit GDT and far-jump to flush CS into the 64-bit segment.
     * long_mode_start lives in .boot.text (low identity) — the jump is
     * still to a LOW address; it only switches CS to 64-bit. */
    lgdt    gdt64_descriptor
    ljmp    $0x08, $long_mode_start

hang32:
    cli
    hlt
    jmp     hang32

/* ---------- 64-bit long-mode trampoline tail ---------------------- *
 * Lives in .boot.text — still fetched at the LOW identity address in
 * the brief window after the far-jump. Its sole job is to re-anchor
 * RIP into the higher half by an absolute indirect jump to the
 * high-half VMA of start_kernel_asm_entry. */
    .section .boot.text, "ax"
    .code64
    .align 8
    .globl long_mode_start
long_mode_start:
    /* Reload data segments with the 64-bit data selector (0x10). */
    movw    $0x10, %ax
    movw    %ax, %ds
    movw    %ax, %es
    movw    %ax, %fs
    movw    %ax, %gs
    movw    %ax, %ss

    /* Re-anchor the (low) boot stack — still identity-mapped. */
    movl    $boot_stack_top, %esp

    /* Jump to the HIGHER-HALF virtual address of the kernel head.
     * `movabsq` materialises the full 64-bit link-time VMA of
     * start_kernel_asm_entry (an R_X86_64_64 relocation, representable
     * now that we link a true elf64). The indirect `jmpq *%rax` then
     * lands RIP in the higher half. From here on every kernel symbol
     * is reached at its 0xffffffff80000000+offset address. */
    movabsq $start_kernel_asm_entry, %rax
    jmpq    *%rax

/* ---------- _x86_start_after_loader — LOW UEFI entry shim --------- *
 * The EFI handoff table (in the multiboot header above) can only carry
 * a 32-bit address, so it points the UEFI firmware / efi_stub.S at
 * THIS low symbol rather than the high-half kernel head directly.
 *
 * arch/x86/boot/efi_stub.S far-jumps here in 64-bit long mode after it
 * has: copied the kernel PT_LOAD segments to their p_paddr, built page
 * tables that map BOTH the low identity range AND the higher half
 * (PML4[0] + PML4[511]), loaded CR3, and lgdt'd the kernel's gdt64.
 *
 * All this shim does is re-anchor RIP into the higher half by an
 * absolute indirect jump to _x86_start_after_loader_high
 * (arch/x86/kernel/head_64.S). It deliberately does NOT re-zero .bss
 * (UEFI firmware NOBITS-zeroes the image for us). */
    .globl  _x86_start_after_loader
_x86_start_after_loader:
    movabsq $_x86_start_after_loader_high, %rax
    jmpq    *%rax

/* ---------- 64-bit GDT used to enter long mode -------------------- *
 *   0x00 null / 0x08 kernel code / 0x10 kernel data
 *   0x18 user data / 0x20 user code / 0x28+0x30 TSS (filled at runtime)
 * Lives in .boot.data (low VMA) so the .head.text 32-bit stub's
 * `lgdt gdt64_descriptor` and the handoff table's `.long gdt64` both
 * resolve to 32-bit addresses. */
    .section .boot.data, "aw"
    .align 8
    .globl gdt64
gdt64:
    .quad   0x0000000000000000      /* 0x00: null */
    .quad   0x00AF9A000000FFFF      /* 0x08: 64-bit kernel code */
    .quad   0x00CF92000000FFFF      /* 0x10: 64-bit kernel data */
    .quad   0x00CFF2000000FFFF      /* 0x18: user 64-bit data   */
    .quad   0x00AFFA000000FFFF      /* 0x20: user 64-bit code   */
    .quad   0x0000000000000000      /* 0x28: TSS low  (runtime) */
    .quad   0x0000000000000000      /* 0x30: TSS high (runtime) */
gdt64_end:

gdt64_descriptor:
    .word   gdt64_end - gdt64 - 1
    /* Base is a LOW 32-bit address (.boot.data) — a .long is correct
     * and the lgdt operand format expects a 4-byte base in 32-bit mode
     * anyway. */
    .long   gdt64

/* ---------- Bookkeeping globals (.boot.data) ---------------------- *
 * mb_magic / mb_info / boot_via_efi / efi_fb_info live in the LOW
 * boot region so the 32-bit stub can write mb_magic/mb_info and the
 * EFI handoff table can carry their 32-bit addresses. The kernel
 * proper reaches them via accessor functions (arch/x86/kernel/
 * boot_info_asm.S) using RIP-relative addressing, which works from
 * the higher half too (the boot region is within ±2 GiB of the
 * kernel image in physical RAM, but the RIP-relative displacement is
 * computed against the *virtual* layout — see boot_info_asm.S). */
    .section .boot.data, "aw"
    .globl  mb_magic
mb_magic: .long 0
    .globl  mb_info
mb_info:  .long 0

    /* boot_via_efi: int32 flag, default 0 ("multiboot path"). The EFI
     * stub patches it to 1 via the +56 handoff slot. Kept here (not as
     * an Adder global) so the handoff table's 32-bit `.long` is valid.
     * arch/x86/kernel/e820.ad reads it via the get_boot_via_efi() /
     * set_boot_via_efi_asm() accessors in boot_info_asm.S. */
    .align 4
    .globl  boot_via_efi
boot_via_efi: .long 0

/* ---------- Page tables (.pgtables) -------------------------------- *
 * NOBITS section, kept OUT of .bss: head_64.S's bss-zero loop runs
 * with paging already enabled, so zeroing pml4/pdpt_* would invalidate
 * the active CR3-rooted tree. Each table is 4 KiB aligned.
 *
 *   pml4       PML4[0] -> pdpt_low, PML4[511] -> pdpt_high
 *   pdpt_low   4 GiB low identity (4× 1 GiB pages)
 *   pdpt_high  the higher half (entries 510, 511 -> phys 0 / 1 GiB)
 */
    .section .pgtables, "aw", @nobits
    .align 4096
    .globl pml4
pml4:
    .skip 4096
    .globl pdpt_low
pdpt_low:
    .skip 4096
    .globl pdpt_high
pdpt_high:
    .skip 4096

/* ---------- Boot stack (.boot.bss) -------------------------------- *
 * The boot stack lives in the LOW boot region (.boot.bss), accessed
 * only via %esp/%rsp. It is identity-mapped and never high-half
 * relocated; head_64.S's high-half BSS-zero pass clears only
 * [__bss_start,__bss_end), which is the high-half .bss — not this. */
    .section .boot.bss, "aw", @nobits
    .align 16
    .globl boot_stack_bottom
boot_stack_bottom:
    .skip 16384                 /* 16 KiB boot stack */
    .globl boot_stack_top
boot_stack_top:
