/*
 * arch/x86/boot/efi_stub.S - Hamnix native UEFI PE/COFF entry stub.
 *
 * This file is assembled and linked into a standalone PE32+ EFI application
 * (`build/hamnix-bootx64.efi`) that UEFI firmware loads directly from the
 * EFI System Partition at \EFI\BOOT\BOOTX64.EFI. No GRUB-EFI middleman.
 *
 * Mirrors the role of arch/x86/boot/header.S for the multiboot1 path:
 * it is the first piece of Hamnix code firmware executes. Where header.S
 * has to crawl out of 32-bit protected mode into long mode, the EFI entry
 * arrives already in 64-bit long mode with identity-mapped low memory and
 * boot services still active.
 *
 * What this stub does today (PATH A: UEFI-side ELF loader, M16.125):
 *   1. Receive EFI_HANDLE in %rcx, EFI_SYSTEM_TABLE* in %rdx (Microsoft
 *      x64 calling convention, per UEFI Specification 2.x §2.3.4).
 *   2. Stash both into well-known globals (efi_image_handle /
 *      efi_system_table) so any later kernel code can pull them back.
 *   3. Write "[hamnix] EFI entry reached\r\n" to the 16550A UART at
 *      COM1 / port 0x3F8.
 *   4. ELF LOAD (new in M16.125):
 *      a. BootServices->HandleProtocol(ImageHandle, &LoadedImageGuid)
 *         to find the device handle the firmware loaded us from.
 *      b. BootServices->HandleProtocol(DeviceHandle, &SfspGuid) to get
 *         the Simple File System Protocol on that device.
 *      c. SFSP->OpenVolume() to get the volume root EFI_FILE_PROTOCOL.
 *      d. root->Open(L"\\hamnix-vmlinux.elf", READ) to get the kernel
 *         ELF file handle.
 *      e. BootServices->AllocatePool(32 MiB) for a scratch buffer.
 *      f. kernel_file->Read(buffer) — pulls the entire ELF into memory.
 *      g. Verify "\x7fELF" magic + ELFCLASS32 (Hamnix kernel is
 *         elf32-i386 by design — every test's `qemu -kernel` argument
 *         depends on it).
 *      h. Walk e_phnum program headers; for each PT_LOAD (p_type==1),
 *         memcpy p_filesz bytes from buffer+p_offset to physical
 *         address p_paddr, then memset (p_memsz - p_filesz) trailing
 *         bytes to zero (BSS within the segment).
 *      i. Scan the loaded image's first 8 KiB for the multiboot1 magic
 *         (0x1BADB002), then read our handoff table that lives right
 *         after the multiboot header:
 *           +48  HAMNIX_HANDOFF_MAGIC ("HAMX" = 0x484D4158)
 *           +52  efi_entry_addr     (= &_x86_start_after_loader)
 *           +56  boot_via_efi_addr  (= &boot_via_efi)
 *         Patch *boot_via_efi_addr = 1 so e820_init() takes the EFI
 *         fallback branch.
 *   5. Call BootServices->GetMemoryMap() into a 16 KiB static buffer
 *      to obtain the current MapKey.
 *   6. Call BootServices->ExitBootServices(ImageHandle, MapKey). Retry
 *      up to EFI_EXIT_RETRY_MAX times on EFI_INVALID_PARAMETER (stale
 *      MapKey because firmware allocated between GetMemoryMap and
 *      ExitBootServices).
 *   7. Write "[hamnix] post-EFI handoff complete\r\n" to COM1.
 *   8. Build identity-mapped page tables in the stub's own .bss:
 *      PML4[0]->PDPT, PDPT[0..3]->1 GiB pages covering [0, 4 GiB).
 *      Mirrors arch/x86/boot/header.S's 1 GiB-page approach so the
 *      kernel runs with the same identity map regardless of boot path.
 *   9. Load our own GDT (kernel-compatible: 0x08=code64, 0x10=data,
 *      same selector shape as arch/x86/boot/header.S's gdt64).
 *  10. Far-jump through CS=0x08 to flush segments, set CR3 = pml4,
 *      reload data segments, then `jmp *efi_kernel_entry` which is
 *      `_x86_start_after_loader` from arch/x86/kernel/head_64.S.
 *
 * Why _x86_start_after_loader and not the ELF e_entry:
 *   The ELF's e_entry points at `_start` (arch/x86/boot/header.S),
 *   which is the 32-bit MULTIBOOT entry — it builds page tables,
 *   switches modes, and jumps to long_mode_start. On the EFI path
 *   we're already in long mode with our own page tables + GDT, so we
 *   skip _start entirely and jump straight to the common post-loader
 *   join point. arch/x86/kernel/head_64.S pre-positions that symbol
 *   for exactly this purpose (M16.120 wiring).
 *
 * Why we don't BSS-zero in the EFI path:
 *   PE/COFF .bss is loaded NOBITS by firmware (same as ELF NOBITS), so
 *   the loaded image's .bss is already firmware-zeroed at image-map
 *   time. The kernel's own .bss (which we just installed via PT_LOAD
 *   copy of the kernel ELF) is firmware-allocated conventional memory
 *   that we then memset(0) in the BSS-trailing-zero loop of step 4h.
 *   _x86_start_after_loader correctly skips the redundant
 *   start_kernel_asm_entry-side BSS-zero loop.
 *
 * Historical context (M16.124 diagnosis — preserved as a record of why
 * the alternative "single hybrid binary" approach was abandoned):
 *
 *   (B1) FILE-MAGIC CONFLICT AT OFFSET 0. UEFI's PE/COFF loader
 *        verifies bytes [0..2) == "MZ"; the kernel ELF starts with
 *        "\x7fELF". A single file cannot satisfy both. Linux's
 *        bzImage works because it's a flat blob — Linux's vmlinux ELF
 *        is NOT what UEFI loads. Resolved by keeping two binaries
 *        (kernel.elf + stub.efi) and having the stub load the ELF at
 *        runtime via SFSP — this commit (PATH A).
 *
 *   (B2) LMA/VMA SPLIT IN .ap_trampoline. The kernel's
 *        arch/x86/kernel/vmlinux.lds places .ap_trampoline at
 *        VMA=0x8000 (SIPI delivery target) but LMA next to .data.
 *        ELF PT_LOAD's p_paddr vs p_vaddr cleanly expresses this;
 *        PE/COFF can't. PATH A preserves the ELF format and the
 *        VMA/LMA split — our loader honours p_paddr (the LMA), and
 *        smp.ad's memcpy still moves the trampoline bytes to 0x8000
 *        before SIPI.
 *
 *   (B3) IMAGE-BASE RELOCATION. The kernel is non-PIC. PATH A
 *        doesn't move the kernel image — we copy PT_LOADs to their
 *        recorded p_paddr (which == the kernel's link-time absolute
 *        address, 0x100000+). No relocation needed.
 *
 *   (B4) GDT / CR3 HANDOFF FROM FIRMWARE. After ExitBootServices the
 *        EFI stub installs its own page tables and GDT (steps 8 + 9
 *        above) before jumping to the kernel. Firmware's GDT/CR3 are
 *        no longer referenced.
 *
 * Build:
 *   The Hamnix compiler emits the elf32-i386 kernel image as before.
 *   This file is assembled with `as --64` (true 64-bit elf64-x86-64)
 *   and linked with `ld -m i386pep --subsystem 10` to produce a true
 *   PE32+ EFI_APPLICATION. See scripts/build_iso.sh for the full
 *   invocation.
 */

    .code64

    /* ---- Compile-time constants -------------------------------------
     *
     * EFI_MMAP_BUF_SIZE: GetMemoryMap scratch buffer (16 KiB holds
     * ~341 descriptors at 48 bytes each — far more than any plausible
     * firmware).
     *
     * EFI_EXIT_RETRY_MAX: Bounded retries on ExitBootServices for
     * MapKey staleness.
     *
     * KERNEL_ELF_BUF_SIZE: AllocatePool capacity for the kernel ELF.
     * Today's kernel.elf is ~3.6 MB; reserve 32 MiB to leave room for
     * growth (initramfs blob lives in .rodata and is the dominant
     * size driver).
     *
     * HAMNIX_HANDOFF_MAGIC: "HAMX" little-endian, used as a sanity
     * check on the handoff table that arch/x86/boot/header.S plants
     * right after the multiboot1 header.
     */
    .equ EFI_MMAP_BUF_SIZE,     16384
    .equ EFI_EXIT_RETRY_MAX,    4
    .equ KERNEL_ELF_BUF_SIZE,   (32 * 1024 * 1024)
    .equ HAMNIX_HANDOFF_MAGIC,  0x484D4158      /* "HAMX" */
    .equ MULTIBOOT1_MAGIC,      0x1BADB002

    /* ELF constants (elf32-i386 layout — Hamnix kernel format). */
    .equ EI_MAG0,           0
    .equ ELFMAG0,           0x7f
    .equ ELFMAG1,           0x45    /* 'E' */
    .equ ELFMAG2,           0x4c    /* 'L' */
    .equ ELFMAG3,           0x46    /* 'F' */
    .equ EI_CLASS,          4
    .equ ELFCLASS32,        1
    .equ E_ENTRY32,         24      /* uint32, file offset in ELF32 hdr */
    .equ E_PHOFF32,         28
    .equ E_PHENTSIZE32,     42      /* uint16 */
    .equ E_PHNUM32,         44
    /* ELF32 Phdr fields */
    .equ P_TYPE,            0       /* uint32 */
    .equ P_OFFSET,          4
    .equ P_VADDR,           8
    .equ P_PADDR,           12
    .equ P_FILESZ,          16
    .equ P_MEMSZ,           20
    .equ PT_LOAD,           1

    .section .text, "ax"

    .globl  efi_main
efi_main:
    /* Microsoft x64 calling convention:
     *   %rcx = EFI_HANDLE        ImageHandle
     *   %rdx = EFI_SYSTEM_TABLE* SystemTable */
    cli
    movq    %rcx, efi_image_handle(%rip)
    movq    %rdx, efi_system_table(%rip)

    /* Anchor a 16-KiB stack of our own in .bss. */
    leaq    efi_stub_stack_top(%rip), %rsp

    /* Cache BootServices pointer once. EFI_SYSTEM_TABLE+96 = BootServices. */
    movq    efi_system_table(%rip), %rax
    movq    96(%rax), %rax
    movq    %rax, efi_boot_services(%rip)

    /* Print "[hamnix] EFI entry reached\r\n" over COM1. */
    leaq    efi_marker_msg(%rip), %rsi
    call    efi_serial_puts

    /* =================================================================
     * STEP 4: ELF LOAD via Simple File System Protocol.
     * Each sub-step writes a short progress marker to COM1 so a
     * post-mortem on a hung box can pinpoint where bring-up failed.
     * ================================================================= */

    /* ----- 4a. HandleProtocol(ImageHandle, &LoadedImageGuid, &out) ---
     *
     * EFI_BOOT_SERVICES.HandleProtocol is at offset 152.
     * Signature: EFI_STATUS HandleProtocol(EFI_HANDLE, EFI_GUID*, void**)
     *   rcx = handle, rdx = guid*, r8 = void** out. */
    movq    efi_image_handle(%rip), %rcx
    leaq    loaded_image_guid(%rip), %rdx
    leaq    efi_loaded_image(%rip), %r8
    movq    efi_boot_services(%rip), %rax
    movq    152(%rax), %rax                 /* ->HandleProtocol */
    subq    $0x20, %rsp
    call    *%rax
    addq    $0x20, %rsp
    testq   %rax, %rax
    jnz     .Lefi_elfload_fail

    /* DeviceHandle is at offset 24 in EFI_LOADED_IMAGE_PROTOCOL. */
    movq    efi_loaded_image(%rip), %rax
    movq    24(%rax), %rax
    movq    %rax, efi_device_handle(%rip)

    /* ----- 4b. HandleProtocol(DeviceHandle, &SfspGuid, &out) -------- */
    movq    efi_device_handle(%rip), %rcx
    leaq    sfsp_guid(%rip), %rdx
    leaq    efi_sfsp(%rip), %r8
    movq    efi_boot_services(%rip), %rax
    movq    152(%rax), %rax
    subq    $0x20, %rsp
    call    *%rax
    addq    $0x20, %rsp
    testq   %rax, %rax
    jnz     .Lefi_elfload_fail

    /* ----- 4c. SFSP->OpenVolume(SFSP, &Root) -----------------------
     *
     * EFI_SIMPLE_FILE_SYSTEM_PROTOCOL layout:
     *   off 0: UINT64 Revision
     *   off 8: OpenVolume(This, EFI_FILE_PROTOCOL **Root)
     */
    movq    efi_sfsp(%rip), %rcx                /* This */
    leaq    efi_volume_root(%rip), %rdx         /* &Root */
    movq    efi_sfsp(%rip), %rax
    movq    8(%rax), %rax                       /* ->OpenVolume */
    subq    $0x20, %rsp
    call    *%rax
    addq    $0x20, %rsp
    testq   %rax, %rax
    jnz     .Lefi_elfload_fail

    /* ----- 4d. Root->Open(L"\\hamnix-vmlinux.elf", READ, 0, &File) -
     *
     * EFI_FILE_PROTOCOL.Open is at offset 8.
     * Signature:
     *   EFI_STATUS Open(EFI_FILE_PROTOCOL *This,        // rcx
     *                   EFI_FILE_PROTOCOL **NewHandle,  // rdx
     *                   CHAR16 *FileName,               // r8
     *                   UINT64 OpenMode,                // r9
     *                   UINT64 Attributes);             // [rsp+32]
     * OpenMode = EFI_FILE_MODE_READ = 1.
     */
    movq    efi_volume_root(%rip), %rcx
    leaq    efi_kernel_file(%rip), %rdx
    leaq    kernel_path_w(%rip), %r8
    movq    $1, %r9                         /* EFI_FILE_MODE_READ */
    subq    $0x30, %rsp
    movq    $0, 0x20(%rsp)                  /* Attributes = 0 */
    movq    efi_volume_root(%rip), %rax
    movq    8(%rax), %rax                   /* ->Open */
    call    *%rax
    addq    $0x30, %rsp
    testq   %rax, %rax
    jnz     .Lefi_elfload_fail

    /* ----- 4e. AllocatePool(EfiLoaderData, 32 MiB, &Buffer) ---------
     *
     * EFI_BOOT_SERVICES.AllocatePool is at offset 64.
     * Signature:
     *   EFI_STATUS AllocatePool(EFI_MEMORY_TYPE PoolType,  // rcx
     *                           UINTN Size,                // rdx
     *                           VOID **Buffer);            // r8
     * EfiLoaderData = 2.
     */
    movq    $2, %rcx                        /* EfiLoaderData */
    movq    $KERNEL_ELF_BUF_SIZE, %rdx
    leaq    efi_kernel_buf(%rip), %r8
    movq    efi_boot_services(%rip), %rax
    movq    64(%rax), %rax                  /* ->AllocatePool */
    subq    $0x20, %rsp
    call    *%rax
    addq    $0x20, %rsp
    testq   %rax, %rax
    jnz     .Lefi_elfload_fail

    /* ----- 4f. File->Read(File, &BufferSize, Buffer) ---------------
     *
     * EFI_FILE_PROTOCOL.Read is at offset 32.
     * BufferSize is IN/OUT: we set it to our capacity, the call
     * writes back the actual bytes read.
     */
    movq    $KERNEL_ELF_BUF_SIZE, efi_kernel_size(%rip)
    movq    efi_kernel_file(%rip), %rcx
    leaq    efi_kernel_size(%rip), %rdx
    movq    efi_kernel_buf(%rip), %r8
    movq    efi_kernel_file(%rip), %rax
    movq    32(%rax), %rax                  /* ->Read */
    subq    $0x20, %rsp
    call    *%rax
    addq    $0x20, %rsp
    testq   %rax, %rax
    jnz     .Lefi_elfload_fail

    leaq    efi_msg_elfread(%rip), %rsi
    call    efi_serial_puts

    /* ----- 4g. Verify ELF magic + ELFCLASS32 ------------------------ */
    movq    efi_kernel_buf(%rip), %rax
    cmpb    $ELFMAG0, 0(%rax)
    jne     .Lefi_elf_bad
    cmpb    $ELFMAG1, 1(%rax)
    jne     .Lefi_elf_bad
    cmpb    $ELFMAG2, 2(%rax)
    jne     .Lefi_elf_bad
    cmpb    $ELFMAG3, 3(%rax)
    jne     .Lefi_elf_bad
    cmpb    $ELFCLASS32, EI_CLASS(%rax)
    jne     .Lefi_elf_bad

    /* ----- 4h. Walk program headers, copy PT_LOAD segments ----------
     *
     * For an ELF32:
     *   e_phoff       at file offset 28 (uint32)
     *   e_phentsize   at file offset 42 (uint16)
     *   e_phnum       at file offset 44 (uint16)
     *
     * Each Phdr (Elf32_Phdr) is 32 bytes:
     *   off 0  p_type
     *   off 4  p_offset
     *   off 8  p_vaddr
     *   off 12 p_paddr
     *   off 16 p_filesz
     *   off 20 p_memsz
     *
     * For each phdr with p_type == PT_LOAD:
     *   memcpy(p_paddr, buffer + p_offset, p_filesz)
     *   memset(p_paddr + p_filesz, 0, p_memsz - p_filesz)
     */
    movq    efi_kernel_buf(%rip), %rax
    movl    E_PHOFF32(%rax), %r10d          /* r10 = e_phoff (zero-ext) */
    movzwl  E_PHENTSIZE32(%rax), %r11d      /* r11 = e_phentsize */
    movzwl  E_PHNUM32(%rax), %r12d          /* r12 = e_phnum */

    /* r13 = current phdr pointer = buffer + e_phoff. */
    leaq    (%rax, %r10), %r13
    /* r14 = phdr index. */
    xorl    %r14d, %r14d

.Lphdr_loop:
    cmpl    %r12d, %r14d
    jae     .Lphdr_done

    /* p_type test. */
    movl    P_TYPE(%r13), %eax
    cmpl    $PT_LOAD, %eax
    jne     .Lphdr_skip

    /* Compute source = buffer + p_offset. */
    movq    efi_kernel_buf(%rip), %rsi
    movl    P_OFFSET(%r13), %eax            /* zero-extend uint32 */
    addq    %rax, %rsi
    /* Destination = p_paddr (zero-extended uint32 → 64-bit phys). */
    movl    P_PADDR(%r13), %edi
    /* filesz, memsz. */
    movl    P_FILESZ(%r13), %ecx
    movl    P_MEMSZ(%r13), %edx

    /* memcpy %ecx bytes from %rsi to %rdi. */
    cld
    rep movsb                               /* rsi/rdi/rcx all auto-update */

    /* Trailing-BSS zero: rdi now points just past the copied bytes.
     * Zero (memsz - filesz) trailing bytes. */
    movl    P_MEMSZ(%r13), %eax
    movl    P_FILESZ(%r13), %r8d
    subl    %r8d, %eax                      /* eax = trailing zero count */
    movl    %eax, %ecx
    xorl    %eax, %eax
    rep stosb

.Lphdr_skip:
    addq    %r11, %r13                      /* next phdr (r11 = phentsize) */
    incl    %r14d
    jmp     .Lphdr_loop

.Lphdr_done:
    leaq    efi_msg_elfcopy(%rip), %rsi
    call    efi_serial_puts

    /* ----- 4i. Locate the Hamnix EFI handoff table ------------------
     *
     * Scan the first 8 KiB of the LOADED kernel image (now at its
     * link-time addresses, starting at 0x100000 for .head.text) for
     * the multiboot1 magic 0x1BADB002. The handoff table planted by
     * arch/x86/boot/header.S lives at multiboot_header + 48:
     *
     *   +48  HAMNIX_HANDOFF_MAGIC (0x484D4158, "HAMX")
     *   +52  uint32 efi_entry_addr     = &_x86_start_after_loader
     *   +56  uint32 boot_via_efi_addr  = &boot_via_efi
     *
     * Why scan instead of hard-coding 0x100000+offset:
     *   - The kernel image's first PT_LOAD currently starts at
     *     0x100000 (vmlinux.lds: `. = 0x100000;`). If that ever moves
     *     (e.g. a future higher-half layout), or if the multiboot
     *     header gets repositioned within .head.text, a fixed offset
     *     silently breaks. The scan-for-magic idiom is exactly how
     *     real multiboot loaders find the kernel's header bytes —
     *     mirroring it here keeps the EFI loader robust against
     *     kernel-side layout drift.
     *   - The scan window is bounded (8 KiB, per multiboot1 spec) so
     *     the cost is trivial: ~2048 dword comparisons in the worst
     *     case.
     */
    movq    $0x100000, %rsi                 /* scan from kernel .head.text */
    movl    $2048, %ecx                     /* 8 KiB / 4 */
.Lscan_mb:
    cmpl    $MULTIBOOT1_MAGIC, (%rsi)
    je      .Lscan_mb_hit
    addq    $4, %rsi                        /* multiboot magic is 4-byte aligned */
    decl    %ecx
    jnz     .Lscan_mb
    /* Magic not found — kernel image we loaded isn't a Hamnix
     * multiboot kernel. Bail. */
    jmp     .Lefi_elf_bad

.Lscan_mb_hit:
    /* %rsi = address of the multiboot1 magic. Read +48..+56. */
    cmpl    $HAMNIX_HANDOFF_MAGIC, 48(%rsi)
    jne     .Lefi_handoff_bad
    movl    52(%rsi), %eax                  /* efi_entry_addr */
    movl    %eax, efi_kernel_entry(%rip)
    movl    56(%rsi), %eax                  /* boot_via_efi_addr */
    movq    %rax, efi_boot_via_efi_ptr(%rip)

    /* Patch *boot_via_efi = 1 so e820_init() takes the EFI fallback. */
    movq    efi_boot_via_efi_ptr(%rip), %rax
    movl    $1, (%rax)

    leaq    efi_msg_handoff(%rip), %rsi
    call    efi_serial_puts

    /* =================================================================
     * STEP 5+6: GetMemoryMap + ExitBootServices retry loop.
     * (Unchanged from M16.111. Comments trimmed; see git history for
     * the full annotation.)
     * ================================================================= */
    movl    $0, %ebx                        /* retry counter */

.Lefi_exit_retry:
    movq    $EFI_MMAP_BUF_SIZE, efi_mmap_size(%rip)

    leaq    efi_mmap_size(%rip),     %rcx
    leaq    efi_mmap_buf(%rip),      %rdx
    leaq    efi_mmap_key(%rip),      %r8
    leaq    efi_mmap_descsize(%rip), %r9
    subq    $0x30, %rsp
    leaq    efi_mmap_descver(%rip), %r10
    movq    %r10, 0x20(%rsp)
    movq    efi_boot_services(%rip), %rax
    movq    56(%rax), %rax                  /* ->GetMemoryMap */
    call    *%rax
    addq    $0x30, %rsp

    movq    efi_image_handle(%rip), %rcx
    movq    efi_mmap_key(%rip),     %rdx
    movq    efi_boot_services(%rip), %rax
    movq    232(%rax), %rax                 /* ->ExitBootServices */
    subq    $0x20, %rsp
    call    *%rax
    addq    $0x20, %rsp

    testq   %rax, %rax
    jz      .Lefi_exit_ok

    incl    %ebx
    cmpl    $EFI_EXIT_RETRY_MAX, %ebx
    jb      .Lefi_exit_retry

    leaq    efi_exit_fail_msg(%rip), %rsi
    call    efi_serial_puts
    jmp     .Lefi_halt

.Lefi_exit_ok:
    leaq    efi_post_handoff_msg(%rip), %rsi
    call    efi_serial_puts

    /* =================================================================
     * STEP 8: Build identity-mapped page tables (1 GiB pages, 4 GiB).
     * Mirrors arch/x86/boot/header.S's PML4[0]->PDPT, PDPT[0..3]->1GiB
     * arrangement. Tables live in this stub's .bss (efi_pml4 / efi_pdpt
     * — 4 KiB aligned via .align 4096).
     *
     * PML4[0] = &efi_pdpt | (RW | P) = &efi_pdpt | 0x3
     * PDPT[i] = (i << 30) | (PS | RW | P) = (i << 30) | 0x83
     *
     * NOTE: We don't set US (User/Supervisor=1) on these PTEs because
     *       the kernel runs at CPL=0 and the kernel-side code does
     *       NOT expect supervisor-only enforcement on the bootstrap
     *       map. Header.S sets US=1 too — kept identical for
     *       compatibility.
     * ================================================================= */
    leaq    efi_pdpt(%rip), %rax
    orq     $0x7, %rax
    leaq    efi_pml4(%rip), %rdi
    movq    %rax, (%rdi)

    /* PDPT entries 0..3: 1 GiB pages at 0, 1G, 2G, 3G. */
    leaq    efi_pdpt(%rip), %rdi
    movq    $0x87, %rax                     /* PS|US|RW|P, phys=0 */
    movq    %rax, 0(%rdi)
    addq    $0x40000000, %rax
    movq    %rax, 8(%rdi)
    addq    $0x40000000, %rax
    movq    %rax, 16(%rdi)
    addq    $0x40000000, %rax
    movq    %rax, 24(%rdi)

    /* Debug marker: page tables built. */
    leaq    efi_msg_pgtab(%rip), %rsi
    call    efi_serial_puts

    /* =================================================================
     * STEP 9: Load our own GDT.
     * Layout matches arch/x86/boot/header.S's gdt64 (CS=0x08, DS=0x10).
     *
     * PE/COFF has no .reloc section so the static `.long efi_gdt`
     * inside efi_gdt_descriptor holds the LINK-time offset (image-
     * base 0), not the run-time VMA. Patch it at runtime via leaq.
     * ================================================================= */
    leaq    efi_gdt(%rip), %rax
    movq    %rax, efi_gdt_descriptor_base(%rip)
    lgdt    efi_gdt_descriptor(%rip)

    /* Debug marker: GDT loaded. */
    leaq    efi_msg_gdt(%rip), %rsi
    call    efi_serial_puts

    /* =================================================================
     * STEP 10: Set CR3, far-jump to flush CS, reload data segments,
     * jump to _x86_start_after_loader (read from the handoff table).
     *
     * We're already in long mode and CR0.PG is on (firmware set them).
     * Loading CR3 with our PML4 swaps the address space to our
     * identity map; the very next instruction must still be present
     * in the new map. Since our PML4 identity-maps the first 4 GiB
     * and this code lives below 4 GiB (the EFI stub binary is loaded
     * by firmware below 4 GiB on every real-world UEFI implementation),
     * the page following the CR3 write is still valid.
     * ================================================================= */
    leaq    efi_pml4(%rip), %rax
    movq    %rax, %cr3

    /* Debug marker: CR3 swapped — if we reach this serial puts call,
     * the new identity map is functional. */
    leaq    efi_msg_cr3(%rip), %rsi
    call    efi_serial_puts

    /* Far-jump to flush CS into our 64-bit code segment 0x08.
     *
     * GOTCHA: the PE32+ image has NO .reloc section, so UEFI relocates
     * the image to a firmware-chosen base but DOES NOT fix up any
     * address-typed data in .rdata. A literal `.long .Lefi_long_mode_resume`
     * therefore holds the LINK-time offset (image-base 0), not the
     * run-time VMA. We must compute the run-time address of the
     * resume label at runtime and write it into the far-jmp operand
     * before issuing the jump.
     *
     * Steps:
     *   1. leaq .Lefi_long_mode_resume(%rip), %rax — runtime VMA.
     *   2. movq %rax, efi_far_jmp_offset(%rip) — patch the 8-byte
     *      offset slot of efi_far_jmp_target.
     *   3. rex.w ljmp *efi_far_jmp_target(%rip) — far jump using the
     *      now-correct offset + the static CS selector 0x08. */
    leaq    .Lefi_long_mode_resume(%rip), %rax
    movq    %rax, efi_far_jmp_offset(%rip)
    rex.w ljmp *efi_far_jmp_target(%rip)

    /* Note: control resumes at .Lefi_long_mode_resume because that's
     * the offset in efi_far_jmp_target's m16:64 operand. */

.Lefi_long_mode_resume:
    /* Reload data segments with the kernel's data selector (0x10). */
    movw    $0x10, %ax
    movw    %ax, %ds
    movw    %ax, %es
    movw    %ax, %fs
    movw    %ax, %gs
    movw    %ax, %ss

    /* Re-anchor the stack on our own stack. */
    leaq    efi_stub_stack_top(%rip), %rsp

    /* Debug marker: long-mode resume reached — far jump worked. */
    leaq    efi_msg_ljmp(%rip), %rsi
    call    efi_serial_puts

    /* Match multiboot1 entry register state expected at
     * _x86_start_after_loader:
     *   - %rax / %rbx / %rcx / %rdx don't carry information on the
     *     EFI path (no multiboot info struct). Zero them so the
     *     kernel sees a deterministic state.
     *   - The kernel reads `boot_via_efi` (already set to 1 above)
     *     to choose its e820 path; the multiboot magic/info pointer
     *     are left at zero and e820_init() takes the EFI branch
     *     before it consults them. */
    xorl    %eax, %eax
    xorl    %ebx, %ebx
    xorl    %ecx, %ecx
    xorl    %edx, %edx

    /* Jump to _x86_start_after_loader. The handoff table stashed
     * its absolute address in efi_kernel_entry; the value is a 32-bit
     * kernel-VMA (kernel is linked elf32-i386 with VMAs < 4 GiB), and
     * we identity-map the first 4 GiB, so a direct 64-bit jump works. */
    movl    efi_kernel_entry(%rip), %eax
    jmpq    *%rax

    /* ---- Failure paths --------------------------------------------- */
.Lefi_elfload_fail:
    leaq    efi_msg_elfload_fail(%rip), %rsi
    call    efi_serial_puts
    jmp     .Lefi_halt

.Lefi_elf_bad:
    leaq    efi_msg_elf_bad(%rip), %rsi
    call    efi_serial_puts
    jmp     .Lefi_halt

.Lefi_handoff_bad:
    leaq    efi_msg_handoff_bad(%rip), %rsi
    call    efi_serial_puts
    jmp     .Lefi_halt

.Lefi_halt:
    cli
    hlt
    jmp     .Lefi_halt

    .globl  efi_main_end
efi_main_end:


/* efi_serial_puts:
 *   %rsi = pointer to NUL-terminated ASCII string
 *   Trashes: %rax, %rcx, %rdx, %rsi
 *
 * Writes each byte to port 0x3F8 after polling LSR bit 5 (THR empty).
 */
efi_serial_puts:
    movw    $0x3F8, %dx
.Lputs_next:
    movb    (%rsi), %al
    testb   %al, %al
    jz      .Lputs_done
    movw    $0x3FD, %dx
.Lputs_wait:
    inb     %dx, %al
    testb   $0x20, %al
    jz      .Lputs_wait
    movb    (%rsi), %al
    movw    $0x3F8, %dx
    outb    %al, %dx
    incq    %rsi
    jmp     .Lputs_next
.Lputs_done:
    ret


/* ---------- Read-only data --------------------------------------- *
 *
 * Note: PE/COFF object files written by `ld -m i386pep` group .rodata
 * into the .rdata section by convention; matches what header.S-side
 * test scripts expect to see in the linked image.
 */
    .section .rdata, "a"
    .align 8
efi_marker_msg:
    .asciz  "[hamnix] EFI entry reached\r\n"
efi_msg_elfread:
    .asciz  "[hamnix] EFI: kernel ELF read OK\r\n"
efi_msg_elfcopy:
    .asciz  "[hamnix] EFI: PT_LOAD copy complete\r\n"
efi_msg_handoff:
    .asciz  "[hamnix] EFI: handoff table located\r\n"
efi_post_handoff_msg:
    .asciz  "[hamnix] post-EFI handoff complete\r\n"
efi_exit_fail_msg:
    .asciz  "[hamnix] EFI ExitBootServices retries exhausted; halt\r\n"
efi_msg_elfload_fail:
    .asciz  "[hamnix] EFI: SFSP file load failed; halt\r\n"
efi_msg_elf_bad:
    .asciz  "[hamnix] EFI: bad ELF magic or class; halt\r\n"
efi_msg_handoff_bad:
    .asciz  "[hamnix] EFI: kernel handoff table missing; halt\r\n"
efi_msg_pgtab:
    .asciz  "[hamnix] EFI: identity page tables built\r\n"
efi_msg_gdt:
    .asciz  "[hamnix] EFI: GDT loaded\r\n"
efi_msg_cr3:
    .asciz  "[hamnix] EFI: CR3 swap OK\r\n"
efi_msg_ljmp:
    .asciz  "[hamnix] EFI: long-mode ljmp OK\r\n"

    /* UEFI protocol GUIDs (16-byte structures, little-endian on x86).
     *
     * EFI_LOADED_IMAGE_PROTOCOL_GUID:
     *   5b1b31a1-9562-11d2-8e3f-00a0c969723b */
    .align 8
loaded_image_guid:
    .long   0x5b1b31a1
    .short  0x9562
    .short  0x11d2
    .byte   0x8e, 0x3f, 0x00, 0xa0, 0xc9, 0x69, 0x72, 0x3b

    /* EFI_SIMPLE_FILE_SYSTEM_PROTOCOL_GUID:
     *   964e5b22-6459-11d2-8e39-00a0c969723b */
sfsp_guid:
    .long   0x964e5b22
    .short  0x6459
    .short  0x11d2
    .byte   0x8e, 0x39, 0x00, 0xa0, 0xc9, 0x69, 0x72, 0x3b

    /* UCS-2 path to the kernel ELF on the ESP. Backslash-separated,
     * NUL-terminated. Each ASCII char is followed by a zero byte for
     * the high half of the UCS-2 unit. */
kernel_path_w:
    .short  '\\', 'h', 'a', 'm', 'n', 'i', 'x', '-'
    .short  'v', 'm', 'l', 'i', 'n', 'u', 'x', '.'
    .short  'e', 'l', 'f', 0

    /* GDT (3 entries, mirrors arch/x86/boot/header.S's gdt64). The
     * GDT entries are all immediate constants so they need no PE
     * relocation. The descriptor (limit + base) is runtime-patched
     * in .data because PE/COFF has no .reloc and we can't trust a
     * static `.long efi_gdt` to survive image-base relocation. */
    .align 8
    .globl efi_gdt
efi_gdt:
    .quad   0x0000000000000000              /* 0x00 null */
    .quad   0x00AF9A000000FFFF              /* 0x08 64-bit code (L=1) */
    .quad   0x00CF92000000FFFF              /* 0x10 64-bit data */
efi_gdt_end:


/* ---------- Writable data --------------------------------------- *
 * Firmware-handoff state + ELF load scratch. Stashed in .data
 * (initialised) and .bss (NOBITS, firmware-zeroed at image map).
 */
    .section .data, "aw"
    .align 8
    .globl efi_image_handle
efi_image_handle:           .quad 0
    .globl efi_system_table
efi_system_table:           .quad 0
    .globl efi_boot_services
efi_boot_services:          .quad 0
    .globl efi_loaded_image
efi_loaded_image:           .quad 0
    .globl efi_device_handle
efi_device_handle:          .quad 0
    .globl efi_sfsp
efi_sfsp:                   .quad 0
    .globl efi_volume_root
efi_volume_root:            .quad 0
    .globl efi_kernel_file
efi_kernel_file:            .quad 0
    .globl efi_kernel_buf
efi_kernel_buf:             .quad 0
    .globl efi_kernel_size
efi_kernel_size:            .quad 0
    /* Address of _x86_start_after_loader pulled out of the kernel's
     * handoff table (planted by arch/x86/boot/header.S). Stored as a
     * uint32 because the kernel is elf32-i386 (VMAs < 4 GiB). */
    .globl efi_kernel_entry
efi_kernel_entry:           .long 0
    .long 0                                 /* pad to 8-byte align */

    /* GDT descriptor (limit + base). Lives in .data because the
     * 8-byte base is runtime-patched in efi_main (PE/COFF has no
     * .reloc, so the link-time `efi_gdt` value is not the VMA). */
    .align 8
    .globl efi_gdt_descriptor
efi_gdt_descriptor:
    .short  efi_gdt_end - efi_gdt - 1       /* limit (constant) */
    .globl efi_gdt_descriptor_base
efi_gdt_descriptor_base:    .quad 0         /* base (runtime-patched) */

    /* Far-jump operand (runtime-patched). Offset is computed at
     * runtime via leaq + RIP and stored here; CS selector is the
     * literal 0x08 kernel code segment. */
    .align 8
    .globl efi_far_jmp_target
efi_far_jmp_target:
    .globl efi_far_jmp_offset
efi_far_jmp_offset:         .quad 0     /* runtime offset[63:0] */
                            .short 0x08 /* CS selector */
    /* Address of `boot_via_efi` in the loaded kernel, also from the
     * handoff table. The stub writes 1 here before ExitBootServices
     * so e820_init() takes the EFI fallback. Stored as uint64 for
     * easy mov into a pointer register. */
    .globl efi_boot_via_efi_ptr
efi_boot_via_efi_ptr:       .quad 0

    /* GetMemoryMap scratch. */
    .align 8
    .globl efi_mmap_size
efi_mmap_size:              .quad 0
    .globl efi_mmap_key
efi_mmap_key:               .quad 0
    .globl efi_mmap_descsize
efi_mmap_descsize:          .quad 0
    .globl efi_mmap_descver
efi_mmap_descver:           .quad 0


/* ---------- BSS: stack + memory-map buffer + page tables --------- *
 *
 * Page tables (efi_pml4 / efi_pdpt) MUST be 4 KiB aligned (CR3
 * requirement). .bss is NOBITS so firmware zeroes the whole region
 * at image map time — no explicit clear pass needed before installing
 * entries.
 */
    .section .bss, "aw", @nobits
    .align 16
efi_stub_stack_bottom:
    .skip 16384
    .globl efi_stub_stack_top
efi_stub_stack_top:

    .align 16
    .globl efi_mmap_buf
efi_mmap_buf:
    .skip EFI_MMAP_BUF_SIZE

    .align 4096
    .globl efi_pml4
efi_pml4:
    .skip 4096
    .globl efi_pdpt
efi_pdpt:
    .skip 4096
