/*
 * arch/x86/boot/header.S - Pynux multiboot1 entry + 32->64 long-mode transition.
 *
 * Mirrors the role of Linux's arch/x86/boot/header.S (boot protocol header)
 * and arch/x86/boot/compressed/head_64.S (long-mode setup), collapsed into
 * one file for the simpler multiboot1 path. Once the kernel grows enough
 * to justify the split, the long-mode portion will move out.
 *
 * Control flow on a QEMU `-kernel` boot:
 *   1. QEMU acts as a multiboot1 loader. It locates the magic header below,
 *      loads the ELF, and jumps to _start in 32-bit protected mode with
 *      paging off, EAX=0x2BADB002, EBX=&multiboot_info.
 *   2. We set up a small stack, identity-map the first 1 GiB with 2 MiB
 *      pages, enable PAE + EFER.LME + CR0.PG to enter IA-32e compatibility
 *      mode, then far-jump through a 64-bit GDT to land in long mode.
 *   3. The far-jump target is `long_mode_start`, which tail-calls into
 *      arch/x86/kernel/head_64.S's start_kernel_asm_entry.
 *
 * Everything here is hand-written GNU `as` AT&T syntax; the Pynux compiler
 * itself never emits 32-bit code.
 */

    .section .head.text, "ax"
    .code32

/* ---------- Multiboot1 header (must live in first 8 KiB of ELF) ----- */
    .align 4
multiboot_header:
    .long   0x1BADB002              /* magic */
    .long   0x00000000              /* flags: none (ELF, aligned mods n/a) */
    .long   -(0x1BADB002 + 0)       /* checksum: magic + flags + ck == 0 */

/* ---------- 32-bit protected-mode entry ---------------------------- */
    .globl  _start
_start:
    cli
    /* Set up a tiny 32-bit stack in .bss. boot_stack_top is provided by
     * the linker script. */
    movl    $boot_stack_top, %esp

    /* Stash multiboot magic + info ptr for diagnostics; we don't parse
     * the info struct yet but want it available later. */
    movl    %eax, mb_magic
    movl    %ebx, mb_info

    /* Verify we were booted by a multiboot loader. If not, halt loudly. */
    cmpl    $0x2BADB002, %eax
    jne     hang32

    /* ----- Build identity-mapped page tables ------------------------ *
     * Layout (PAE/long mode 4-level paging):
     *   PML4[0]  -> PDPT
     *   PDPT[0]  -> PD   (covers first 1 GiB via 2 MiB pages)
     *   PD[i]    -> 2 MiB page at i << 21, for i in 0..511
     * Total identity-mapped: 1 GiB. Pynux is well under that for M16.x.   */
    movl    $pml4, %edi
    movl    $pdpt, %eax
    orl     $0x7, %eax              /* US | RW | P */
    movl    %eax, (%edi)

    movl    $pdpt, %edi
    movl    $pd, %eax
    orl     $0x7, %eax              /* US | RW | P */
    movl    %eax, (%edi)

    /* Fill PD with 512 entries, each a 2 MiB page.
     *   bit 0: P  - present
     *   bit 1: RW - writable
     *   bit 2: US - user/supervisor (1 = user accessible)
     *   bit 7: PS - page size (1 for 2 MiB / 1 GiB pages)
     * We set US=1 so user-mode (ring 3) code can read/write/execute the
     * identity-mapped region too. M16.17 introduces a userspace
     * task that issues SYSCALL; without U=1 the very first user-mode
     * instruction fetch faults. This is intentionally simple — proper
     * kernel/user page separation comes when we add per-task page
     * tables. */
    movl    $pd, %edi
    movl    $0, %ecx                /* loop counter */
    movl    $0x87, %eax             /* PS | US | RW | P; phys base = 0 */
1:
    movl    %eax, (%edi)
    movl    $0,   4(%edi)           /* high 32 bits of PTE */
    addl    $0x200000, %eax         /* next 2 MiB */
    addl    $8, %edi
    incl    %ecx
    cmpl    $512, %ecx
    jne     1b

    /* ----- Enable PAE, load CR3, set EFER.LME, then CR0.PG ---------- */
    movl    %cr4, %eax
    orl     $(1 << 5), %eax         /* CR4.PAE */
    movl    %eax, %cr4

    movl    $pml4, %eax
    movl    %eax, %cr3

    movl    $0xC0000080, %ecx       /* IA32_EFER */
    rdmsr
    orl     $(1 << 8), %eax         /* EFER.LME */
    wrmsr

    movl    %cr0, %eax
    orl     $(1 << 31), %eax        /* CR0.PG  - paging on, enter IA-32e */
    movl    %eax, %cr0

    /* Load 64-bit GDT and far-jump to flush CS into the 64-bit segment. */
    lgdt    gdt64_descriptor
    ljmp    $0x08, $long_mode_start

hang32:
    cli
    hlt
    jmp     hang32

/* ---------- 64-bit code path -------------------------------------- */
    .code64
    .align 8
long_mode_start:
    /* Reload data segments with the 64-bit data selector (0x10). In long
     * mode segment bases are ignored for DS/ES/SS but the descriptor must
     * still be loadable.  */
    movw    $0x10, %ax
    movw    %ax, %ds
    movw    %ax, %es
    movw    %ax, %fs
    movw    %ax, %gs
    movw    %ax, %ss

    /* Re-anchor the stack. The 32-bit ESP we set earlier already
     * zero-extended into RSP on the mode switch, but use an explicit
     * 32-bit immediate so the relocation fits in elf32-i386. The address
     * is below 4 GiB so the upper 32 bits stay zero. */
    movl    $boot_stack_top, %esp

    /* Tail-call into the 64-bit head stub, which performs BSS zeroing
     * and finally invokes the Pynux start_kernel(). */
    jmp     start_kernel_asm_entry

/* ---------- 64-bit GDT used to enter long mode -------------------- *
 * Layout chosen for SYSCALL/SYSRET compatibility:
 *   0x00 = null
 *   0x08 = kernel code  (CS for ring 0; SYSCALL CS = STAR[47:32])
 *   0x10 = kernel data  (SS for ring 0; SYSCALL SS = STAR[47:32] + 8)
 *   0x18 = user data    (SYSRET SS = STAR[63:48] + 8 = 0x18 with RPL=3)
 *   0x20 = user code    (SYSRET CS = STAR[63:48] + 16 = 0x20 with RPL=3)
 * With STAR[63:48] = 0x10 these selectors align with the SYSRET
 * hardware-imposed +8/+16 offsets. M16.17 introduces the syscall path
 * that depends on this layout.
 */
    .align 8
    .globl gdt64
gdt64:
    .quad   0x0000000000000000      /* 0x00: null */
    /* 0x08: 64-bit code: P=1, DPL=0, S=1, type=code/exec/read, L=1 */
    .quad   0x00AF9A000000FFFF
    /* 0x10: 64-bit data: P=1, DPL=0, S=1, type=data/rw           */
    .quad   0x00CF92000000FFFF
    /* 0x18: user 64-bit data: P=1, DPL=3, S=1, type=data/rw      */
    .quad   0x00CFF2000000FFFF
    /* 0x20: user 64-bit code: P=1, DPL=3, S=1, type=code/exec/read, L=1 */
    .quad   0x00AFFA000000FFFF
    /* 0x28: TSS descriptor low half  (filled in by tss_init at runtime).
     * 0x30: TSS descriptor high half (filled in by tss_init at runtime).
     * 64-bit system descriptors occupy two consecutive GDT slots. We
     * reserve the space here so the GDT's limit stays correct from
     * boot; the contents are zero until tss_init programs them. */
    .quad   0x0000000000000000
    .quad   0x0000000000000000
gdt64_end:

gdt64_descriptor:
    .word   gdt64_end - gdt64 - 1
    .long   gdt64

/* ---------- Bookkeeping globals (.data) --------------------------- */
    .section .data
    .globl  mb_magic
mb_magic: .long 0
    .globl  mb_info
mb_info:  .long 0

/* ---------- Page tables (.pgtables) -------------------------------- *
 * The page tables MUST live outside .bss: head_64.S's bss-zero loop
 * runs with paging already enabled, so if pml4/pdpt/pd were in .bss
 * the very act of zeroing them would invalidate the active CR3-rooted
 * tree, triple-fault on the next memory access, and reset the box.
 * Putting them in a dedicated `.pgtables` section keeps them out of
 * [__bss_start, __bss_end) while still NOBITS (zero-init at load).
 * Each table is 4 KiB aligned because CR3 / page-table walks require
 * 4 KiB granularity.                                                  */
    .section .pgtables, "aw", @nobits
    .align 4096
    .globl pml4
pml4:
    .skip 4096
    .globl pdpt
pdpt:
    .skip 4096
    .globl pd
pd:
    .skip 4096

/* ---------- Boot stack (.bss) ------------------------------------- *
 * Boot stack lives in .bss; it's accessed only via %rsp/%esp so the
 * BSS-zero pass clearing it before start_kernel is fine — by then we
 * have a fresh stack pointer set just above this region.              */
    .section .bss
    .align 16
    .globl boot_stack_bottom
boot_stack_bottom:
    .skip 16384                 /* 16 KiB boot stack — plenty for M16.x */
    .globl boot_stack_top
boot_stack_top:
