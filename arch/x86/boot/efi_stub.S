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
 *      d. root->Open(L"\\hamnix-kernel.elf", READ) to get the kernel
 *         ELF file handle.
 *      e. kernel_file->Read() the ELF header + program-header table into
 *         a small (16 KiB) buffer in this stub's .bss. DELIBERATELY no
 *         whole-file scratch buffer: a multi-MiB AllocatePool buffer can
 *         be placed by firmware INSIDE the kernel's own fixed-LOW load
 *         region, where the segment copies then corrupt the in-flight
 *         phdr walk / segment source (the intermittent OVMF #PF/#GP
 *         ship-blocker this loader was rewritten to kill).
 *      f. (folded into h) segments stream straight from the file to
 *         their load addresses; nothing is staged whole in RAM.
 *      g. Verify ELF magic + ELFCLASS64 (Hamnix kernel is a true
 *         elf64-x86-64 higher-half image; see arch/x86/kernel/kernel.lds).
 *      h. Walk e_phnum program headers; for each PT_LOAD (p_type==1),
 *         SetPosition(p_offset) + Read(p_filesz) DIRECTLY into physical
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
 *      to obtain the current MapKey AND the firmware-reported memory
 *      map. The descriptor array, total size, descriptor stride, and
 *      revision tag are kept in efi_mmap_{buf,size,descsize,descver}
 *      (.bss / .data of this stub's image — EfiLoaderCode/Data, NOT
 *      reclaimed by firmware after ExitBootServices, so the buffer
 *      stays live for the kernel to walk).
 *   6. Call BootServices->ExitBootServices(ImageHandle, MapKey). Retry
 *      up to EFI_EXIT_RETRY_MAX times on EFI_INVALID_PARAMETER (stale
 *      MapKey because firmware allocated between GetMemoryMap and
 *      ExitBootServices).
 *   6b. Stash {buf_phys, size, desc_size, desc_version, present=1} into
 *       the kernel's `efi_mmap_info` struct (.boot.data; address pulled
 *       from handoff slot +68 in step 4i). arch/x86/kernel/e820.ad reads
 *       this on the EFI path to feed memblock the largest free RAM
 *       region the firmware advertised — unlocks > 240 MiB on UEFI
 *       boots that previously hit the conservative fallback ceiling.
 *   7. Write "[hamnix] post-EFI handoff complete\r\n" to COM1.
 *   8. Build identity-mapped page tables in the stub's own .bss:
 *      PML4[0]->PDPT, PDPT[0..511]->1 GiB pages covering [0, 512 GiB).
 *      Mirrors arch/x86/boot/header.S's 1 GiB-page approach but extends
 *      it to the full PDPT instead of just the first 4 entries. The
 *      kernel runs with the same identity map regardless of boot path.
 *      (M16.152: extended from 4 → 512 entries to cover real-hardware
 *      Asus UEFI allocations above 4 GiB — see "[pgtable] EFI/no-mb:
 *      pdpt[4..7]=0" smoking-gun diagnostic from M16.151.)
 *   9. Load the kernel's OWN gdt64 (M16.126). We pick up its address
 *      from the handoff table's +60 slot (planted by header.S). This
 *      is the same 7-entry GDT the multiboot path runs with (null,
 *      kernel CS, kernel DS, user DS, user CS, TSS-lo, TSS-hi), so
 *      tss_init's `ltr $0x28` and any subsequent SYSRET that
 *      references the user CS/DS slots find live descriptors.
 *      (Pre-M16.126 the stub installed a private 3-entry GDT here
 *      that #GPed the kernel inside tss_init.)
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
 *        arch/x86/kernel/kernel.lds places .ap_trampoline at
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
     * EFI_MMAP_BUF_SIZE: GetMemoryMap scratch buffer.
     *
     * Sizing math (UEFI 2.10 §7.2):
     *   - OVMF returns ~30 descriptors at 48 B = ~1.5 KiB.
     *   - Real laptop/desktop firmware (Insyde, AMI, Phoenix) routinely
     *     returns 100..300 descriptors. At the spec-padded 48 B stride
     *     that's 4.8..14.4 KiB; at the 96/128 B stride some firmware
     *     uses (room for vendor extensions), 12..38 KiB.
     *   - Server firmware (Dell, HP, Supermicro) with 1 TiB+ of RAM
     *     can fan out to 600..1000 descriptors as it slices NUMA nodes
     *     and persistent-memory regions: up to ~96 KiB at 96 B stride.
     *
     * 64 KiB gives ~1365 descriptors at 48 B / ~682 at 96 B / ~512 at
     * 128 B — covers every laptop/desktop/workstation reasonably and
     * leaves a healthy margin for future stride growth. The pre-M16.157
     * 16 KiB sizing was tuned for OVMF (where 16 KiB is 10x what
     * firmware actually returns) but is dangerously close to the
     * real-hw ceiling: an Asus i5-4210U whose firmware returns ~200
     * 96 B descriptors needs 19.2 KiB and immediately overflowed
     * 16 KiB — GetMemoryMap returned EFI_BUFFER_TOO_SMALL, the stub
     * (which didn't check the return code) called ExitBootServices
     * with a stale MapKey, ExitBootServices failed, the retry loop
     * exhausted, the stub halted. Without serial the user only saw
     * firmware fall through to its post-boot-fail UI.
     *
     * EFI_EXIT_RETRY_MAX: Bounded retries on ExitBootServices for
     * MapKey staleness (firmware may allocate between GetMemoryMap
     * and ExitBootServices, invalidating MapKey — re-fetch and retry).
     *
     * ELF_HDR_BUF_SIZE: capacity of the small header/phdr buffer. The
     * loader NO LONGER stages the whole ELF in RAM (that whole-file
     * scratch buffer was the intermittent-#PF root cause — see STEP 4).
     * It reads only the ELF header + phdr table here, then streams each
     * PT_LOAD segment straight from the file to its load address, so the
     * kernel ELF can grow arbitrarily large without any capacity ceiling
     * or truncation risk (the self-hosted installer kernel is ~45 MB).
     *
     * HAMNIX_HANDOFF_MAGIC: "HAMX" little-endian, used as a sanity
     * check on the handoff table that arch/x86/boot/header.S plants
     * right after the multiboot1 header.
     *
     * EFI_STATUS_BUFFER_TOO_SMALL: UEFI 2.10 Appendix D — the high bit
     * set in EFI_STATUS marks an error code; 5 is the BUFFER_TOO_SMALL
     * tag. We only need the bit pattern for an immediate compare.
     */
    .equ EFI_MMAP_BUF_SIZE,         65536
    .equ EFI_EXIT_RETRY_MAX,        4
    /* ELF_HDR_BUF_SIZE: capacity of the small buffer that holds ONLY the
     * ELF header + program-header table (the loader streams segments
     * directly to their load addresses, so no whole-file buffer exists).
     * 16 KiB comfortably covers e_phoff (64) + e_phnum*e_phentsize for
     * any sane kernel (the installer kernel has 7 × 56-byte phdrs = 392
     * bytes at offset 64). The bounds guard in STEP 4h rejects any image
     * whose phdr table would extend past what we read. */
    .equ ELF_HDR_BUF_SIZE,          16384
    .equ EFI_FILE_INFO_BUF_SIZE,    512
    .equ HAMNIX_HANDOFF_MAGIC,      0x484D4158  /* "HAMX" */
    .equ MULTIBOOT1_MAGIC,          0x1BADB002

    /* ELF constants (elf64-x86-64 layout — the Hamnix kernel is now a
     * true 64-bit higher-half ELF; see arch/x86/kernel/kernel.lds). */
    .equ EI_MAG0,           0
    .equ ELFMAG0,           0x7f
    .equ ELFMAG1,           0x45    /* 'E' */
    .equ ELFMAG2,           0x4c    /* 'L' */
    .equ ELFMAG3,           0x46    /* 'F' */
    .equ EI_CLASS,          4
    .equ ELFCLASS64,        2
    /* ELF64 header fields */
    .equ E_ENTRY64,         24      /* uint64 */
    .equ E_PHOFF64,         32      /* uint64 */
    .equ E_PHENTSIZE64,     54      /* uint16 */
    .equ E_PHNUM64,         56      /* uint16 */
    /* ELF64 Phdr fields (Elf64_Phdr is 56 bytes) */
    .equ P_TYPE,            0       /* uint32 */
    .equ P_FLAGS,           4       /* uint32 */
    .equ P_OFFSET,          8       /* uint64 */
    .equ P_VADDR,           16      /* uint64 */
    .equ P_PADDR,           24      /* uint64 */
    .equ P_FILESZ,          32      /* uint64 */
    .equ P_MEMSZ,           40      /* uint64 */
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

    /* ----- 4d. Root->Open(L"\\hamnix-kernel.elf", READ, 0, &File) -
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

    /* ================================================================
     * 4d.5 / 4e / 4f — STREAM the kernel ELF straight to its load
     * addresses. NO whole-file scratch buffer.
     *
     * ROOT-CAUSE HISTORY (ship-blocker, found by OVMF visual QA):
     *   The previous loader GetInfo'd the file size, AllocatePool'd a
     *   multi-MiB scratch buffer, File->Read the WHOLE ELF into it, then
     *   `rep movsb`-copied each PT_LOAD from buffer+p_offset to the
     *   fixed-LOW p_paddr (0x100000+). Nothing constrained WHERE firmware
     *   placed that scratch buffer. When OVMF's AllocatePool landed the
     *   buffer INSIDE the kernel's own load region [0x100000, load_hi)
     *   — which it does whenever free RAM outside that region is scarce,
     *   or simply as its allocator layout varies boot-to-boot — the first
     *   segment copy overwrote the buffer's still-in-flight program-header
     *   table and/or the not-yet-copied segment source bytes. The phdr
     *   walk then read a garbage p_paddr and `rep movsb`/`rep stosb`
     *   wrote through a wild pointer, faulting (#PF CR2 near -1, or #GP)
     *   right after the "kernel ELF read OK" marker. Intermittent because
     *   it was gated purely on the firmware's chosen buffer address.
     *   Reproduced deterministically under OVMF at -m 145/150 (buffer
     *   forced into the load region → fault every boot); -m 140/160/1280
     *   placed the buffer clear of the region → clean boot.
     *
     *   The FIX eliminates the scratch buffer's existence: we read ONLY
     *   the ELF header + program-header table into a small fixed buffer
     *   that lives in this stub's .bss (far above the load region, never
     *   aliased by it), then read each PT_LOAD segment DIRECTLY from the
     *   file into its p_paddr. There is no large buffer for firmware to
     *   mis-place, so no overlap is possible regardless of RAM size or
     *   allocator state. (This is also how well-behaved UEFI ELF loaders
     *   stream segments — read-to-load-address, not read-then-copy.)
     *
     * ----- 4e'. Read the ELF header + phdr table into efi_hdr_buf -----
     * The file position is 0 after Open, so the first Read starts at the
     * ELF header. EFI_FILE_PROTOCOL.Read is at vtable offset 32:
     *   EFI_STATUS Read(This=rcx, UINTN *Size=rdx [IN/OUT], Buffer=r8);
     * efi_hdr_read_size is IN (buffer capacity) / OUT (bytes read). */
    movq    $ELF_HDR_BUF_SIZE, efi_hdr_read_size(%rip)
    movq    efi_kernel_file(%rip), %rcx
    leaq    efi_hdr_read_size(%rip), %rdx
    leaq    efi_hdr_buf(%rip), %r8
    movq    efi_kernel_file(%rip), %rax
    movq    32(%rax), %rax                  /* ->Read */
    subq    $0x20, %rsp
    call    *%rax
    addq    $0x20, %rsp
    testq   %rax, %rax
    jnz     .Lefi_elfload_fail

    leaq    efi_msg_elfread(%rip), %rsi
    call    efi_serial_puts

    /* ----- 4g. Verify ELF magic + ELFCLASS64 (from the header copy) -- */
    leaq    efi_hdr_buf(%rip), %rax
    cmpb    $ELFMAG0, 0(%rax)
    jne     .Lefi_elf_bad
    cmpb    $ELFMAG1, 1(%rax)
    jne     .Lefi_elf_bad
    cmpb    $ELFMAG2, 2(%rax)
    jne     .Lefi_elf_bad
    cmpb    $ELFMAG3, 3(%rax)
    jne     .Lefi_elf_bad
    cmpb    $ELFCLASS64, EI_CLASS(%rax)
    jne     .Lefi_elf_bad

    /* ----- 4h. Walk program headers, STREAM each PT_LOAD to p_paddr ---
     *
     * Each Phdr (Elf64_Phdr, 56 bytes):
     *   off 0  p_type   (u32)
     *   off 8  p_offset (u64)  <- byte offset of the segment in the file
     *   off 24 p_paddr  (u64)  <- LOW physical load address (LMA)
     *   off 32 p_filesz (u64)  <- bytes present in the file
     *   off 40 p_memsz  (u64)  <- bytes in memory (>= filesz; BSS tail)
     *
     * For each PT_LOAD:
     *   File->SetPosition(File, p_offset)          (vtable off 56)
     *   File->Read(File, &p_filesz, p_paddr)       (vtable off 32)
     *   memset(p_paddr + p_filesz, 0, p_memsz - p_filesz)
     *
     * The phdr walk state (r12=phnum, r13=phdr ptr, r14=index,
     * r15=phentsize) is held ONLY in MS-x64 callee-saved registers so it
     * survives the SetPosition/Read firmware calls made inside the loop.
     * p_offset/p_paddr/p_filesz/p_memsz are re-read from the stable
     * efi_hdr_buf copy each time they are needed. */
    leaq    efi_hdr_buf(%rip), %rax
    movq    E_PHOFF64(%rax), %r10           /* e_phoff (u64) */
    movzwq  E_PHENTSIZE64(%rax), %r15       /* r15 = e_phentsize */
    movzwq  E_PHNUM64(%rax), %r12           /* r12 = e_phnum */

    /* Bounds guard: the whole phdr table must lie within the bytes we
     * actually read into efi_hdr_buf (e_phoff + e_phnum*e_phentsize <=
     * bytes-read). Otherwise a phdr would be read from uninitialised
     * .bss — treat as a malformed image rather than trust garbage. */
    movq    %r12, %rcx
    imulq   %r15, %rcx
    addq    %r10, %rcx                      /* rcx = phdr table end offset */
    cmpq    efi_hdr_read_size(%rip), %rcx
    ja      .Lefi_elf_bad

    /* r13 = current phdr pointer = efi_hdr_buf + e_phoff. */
    leaq    (%rax, %r10), %r13
    xorq    %r14, %r14                      /* r14 = phdr index */

.Lphdr_loop:
    cmpq    %r12, %r14
    jae     .Lphdr_done

    /* p_type test. */
    movl    P_TYPE(%r13), %eax
    cmpl    $PT_LOAD, %eax
    jne     .Lphdr_skip

    /* File->SetPosition(File, p_offset) — seek to the segment. */
    movq    efi_kernel_file(%rip), %rcx
    movq    P_OFFSET(%r13), %rdx
    movq    efi_kernel_file(%rip), %rax
    movq    56(%rax), %rax                  /* ->SetPosition */
    subq    $0x20, %rsp
    call    *%rax
    addq    $0x20, %rsp
    testq   %rax, %rax
    jnz     .Lefi_elfload_fail

    /* File->Read(File, &size, Buffer) — stream the segment's file bytes
     * DIRECTLY to its physical load address, in a CHUNKED LOOP.
     *
     * EFI_FILE_PROTOCOL.Read is NOT guaranteed to satisfy an arbitrarily
     * large request in a single call: OVMF's FAT driver returns a partial
     * (short) read for multi-hundred-MiB requests. The old code issued ONE
     * Read of the whole p_filesz and asserted it filled the buffer, so a
     * kernel large enough to carry a ~500 MiB squashfs (the full-mirror live
     * image with the Mesa/LLVM software-GL stack -> a ~1.5 GiB kernel) failed
     * at that assert ("SFSP file load failed"). A ~671 MiB baseline kernel
     * happened to fit one firmware read and worked, masking the bug.
     *
     * Loop: request min(remaining, 64 MiB) per call (also dodging any
     * per-call size ceiling), advance the buffer by the bytes actually read,
     * and stop when remaining hits 0. A 0-byte read with bytes still owed is
     * a genuine failure (EOF before p_filesz). Loop state lives in memory
     * (efi_seg_remaining / efi_seg_bufptr) because the phdr-walk pins the
     * only callee-saved registers (r12..r15) and firmware calls clobber the
     * volatiles. Small segments still complete in a single iteration. */
    movq    P_FILESZ(%r13), %rax
    movq    %rax, efi_seg_remaining(%rip)
    movq    P_PADDR(%r13), %rax
    movq    %rax, efi_seg_bufptr(%rip)
.Lseg_read_loop:
    movq    efi_seg_remaining(%rip), %rax
    testq   %rax, %rax
    jz      .Lseg_read_done
    /* cap this request at 64 MiB */
    cmpq    $0x4000000, %rax
    jbe     .Lseg_read_have_size
    movq    $0x4000000, %rax
.Lseg_read_have_size:
    movq    %rax, efi_seg_read_size(%rip)   /* IN: bytes to read this call */
    movq    efi_kernel_file(%rip), %rcx
    leaq    efi_seg_read_size(%rip), %rdx
    movq    efi_seg_bufptr(%rip), %r8
    movq    efi_kernel_file(%rip), %rax
    movq    32(%rax), %rax                  /* ->Read */
    subq    $0x20, %rsp
    call    *%rax
    addq    $0x20, %rsp
    testq   %rax, %rax
    jnz     .Lefi_elfload_fail              /* Read returned an error */
    movq    efi_seg_read_size(%rip), %rax   /* OUT: bytes actually read */
    testq   %rax, %rax
    jz      .Lefi_elfload_fail              /* 0 bytes but more owed => EOF */
    addq    %rax, efi_seg_bufptr(%rip)
    subq    %rax, efi_seg_remaining(%rip)
    jmp     .Lseg_read_loop
.Lseg_read_done:

    /* Trailing-BSS zero: [p_paddr + p_filesz, p_paddr + p_memsz). */
    movq    P_PADDR(%r13), %rdi
    addq    P_FILESZ(%r13), %rdi            /* rdi = first BSS byte */
    movq    P_MEMSZ(%r13), %rcx
    subq    P_FILESZ(%r13), %rcx            /* rcx = trailing zero count */
    xorl    %eax, %eax
    cld
    rep stosb

.Lphdr_skip:
    addq    %r15, %r13                      /* next phdr (r15 = phentsize) */
    incq    %r14
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
     *   +60  uint32 gdt64_addr         = &gdt64
     *
     * The +60 entry (M16.126) is what makes tss_init's `ltr $0x28`
     * not #GP on the UEFI path: we use it to lgdt the kernel's own
     * 7-entry gdt64 (null/k-cs/k-ds/u-ds/u-cs/tss-lo/tss-hi) before
     * the far-jump, replacing this stub's 3-entry private efi_gdt.
     *
     * Why scan instead of hard-coding 0x100000+offset:
     *   - The kernel image's first PT_LOAD currently starts at
     *     0x100000 (kernel.lds: `. = 0x100000;`). If that ever moves
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
    /* %rsi = address of the multiboot1 magic. Read +48..+64. */
    cmpl    $HAMNIX_HANDOFF_MAGIC, 48(%rsi)
    jne     .Lefi_handoff_bad
    movl    52(%rsi), %eax                  /* efi_entry_addr */
    movl    %eax, efi_kernel_entry(%rip)
    movl    56(%rsi), %eax                  /* boot_via_efi_addr */
    movq    %rax, efi_boot_via_efi_ptr(%rip)
    /* M16.126: pull &gdt64 out of the +60 handoff slot. We need the
     * kernel's 7-entry GDT (not this stub's 3-entry private one) so
     * tss_init's ltr $0x28 — and SYSRET's reliance on selectors 0x18
     * / 0x20 — find live descriptors instead of trapping #GP for an
     * out-of-limit selector. Read as uint32: the kernel is now a true
     * higher-half elf64, but EVERY handoff-table target (the
     * _x86_start_after_loader shim, boot_via_efi, gdt64, efi_fb_info)
     * deliberately lives in the LOW boot region (.head.text /
     * .boot.text / .boot.data, VMA ~0x10xxxx), so a 32-bit slot still
     * holds the full address and movl zero-extension is correct. */
    movl    60(%rsi), %eax                  /* gdt64_addr */
    movl    %eax, efi_kernel_gdt_addr(%rip)
    /* GOP capture: pull &efi_fb_info out of the +64 handoff slot. The
     * stub will populate this struct via LocateProtocol(GOP) below,
     * BEFORE ExitBootServices (boot services calls are illegal after
     * that). */
    movl    64(%rsi), %eax                  /* efi_fb_info addr */
    movq    %rax, efi_kernel_fb_info_ptr(%rip)

    /* EFI memory-map handoff: pull &efi_mmap_info out of the +68 slot.
     * We populate this struct AFTER ExitBootServices succeeds (below),
     * because the descriptor array contents in efi_mmap_buf are only
     * known to be the FINAL map once ExitBootServices accepts that
     * GetMemoryMap's MapKey. The struct itself lives in the kernel's
     * LOW .boot.data, so a 32-bit address is the right shape. */
    movl    68(%rsi), %eax                  /* efi_mmap_info addr */
    movq    %rax, efi_kernel_mmap_info_ptr(%rip)

    /* #171: EFI runtime-services handoff. Pull &efi_rt_info out of the
     * +72 slot. We can populate this struct NOW (unlike efi_mmap_info,
     * which must wait for the final post-ExitBootServices map): the
     * EFI_SYSTEM_TABLE and the RuntimeServices/ConfigurationTable
     * pointers it carries are static for the life of the firmware and
     * remain valid after ExitBootServices. The struct lives in the
     * kernel's LOW .boot.data, so a 32-bit address is the right shape.
     * A zero slot means a pre-#171 kernel — skip silently. */
    movl    72(%rsi), %eax                  /* efi_rt_info addr */
    movq    %rax, efi_kernel_rt_info_ptr(%rip)
    testq   %rax, %rax
    jz      .Lefi_rt_handoff_skip
    movq    %rax, %r10                      /* %r10 = &efi_rt_info */
    movq    efi_system_table(%rip), %r11    /* %r11 = EFI_SYSTEM_TABLE * */
    /* num_config_entries = SystemTable->NumberOfTableEntries (off 104) */
    movl    104(%r11), %eax
    movl    %eax, 4(%r10)
    /* system_table pointer (off 8) */
    movq    %r11, 8(%r10)
    /* runtime_services = SystemTable->RuntimeServices (off 88) */
    movq    88(%r11), %rax
    movq    %rax, 16(%r10)
    /* config_table = SystemTable->ConfigurationTable (off 112) */
    movq    112(%r11), %rax
    movq    %rax, 24(%r10)
    /* present = 1 — written LAST so the kernel never sees a torn struct. */
    movl    $1, 0(%r10)
.Lefi_rt_handoff_skip:

    /* Patch *boot_via_efi = 1 so e820_init() takes the EFI fallback. */
    movq    efi_boot_via_efi_ptr(%rip), %rax
    movl    $1, (%rax)

    leaq    efi_msg_handoff(%rip), %rsi
    call    efi_serial_puts

    /* ----- 4j. Capture GOP framebuffer info -------------------------
     *
     * Call BootServices->LocateProtocol(EFI_GRAPHICS_OUTPUT_PROTOCOL_GUID,
     *                                   NULL, &efi_gop). On success,
     * read gop->Mode->{Info, FrameBufferBase, FrameBufferSize} and
     * write the geometry into the kernel's efi_fb_info struct (whose
     * address came from the +64 handoff slot above).
     *
     * Failure (no GOP available — extremely rare on real UEFI hardware,
     * but possible with stripped/minimal firmware) is non-fatal: we
     * leave efi_fb_info.present = 0 and the kernel-side fb_init_early
     * silently falls through with no on-screen output. The kernel
     * still boots; only the GOP console is unavailable.
     *
     * EFI_BOOT_SERVICES.LocateProtocol is at offset 320 (UEFI 2.10
     * §7.3.16 — sequence: HandleProtocol@152 ... LocateProtocol@320).
     * Signature:
     *   EFI_STATUS LocateProtocol(EFI_GUID *Protocol,        // rcx
     *                             VOID     *Registration,    // rdx
     *                             VOID    **Interface);      // r8
     */
    movq    efi_kernel_fb_info_ptr(%rip), %rax
    testq   %rax, %rax
    jz      .Lefi_gop_skip                  /* old kernel, no +64 slot */

    /* LocateProtocol(&GOP_GUID, NULL, &efi_gop) */
    leaq    gop_guid(%rip), %rcx            /* Protocol = &GOP_GUID */
    xorl    %edx, %edx                      /* Registration = NULL  */
    leaq    efi_gop(%rip), %r8              /* &Interface           */
    movq    efi_boot_services(%rip), %rax
    movq    320(%rax), %rax                 /* ->LocateProtocol     */
    subq    $0x20, %rsp
    call    *%rax
    addq    $0x20, %rsp
    testq   %rax, %rax
    jnz     .Lefi_gop_skip                  /* not found / disabled */

    /* %rax = EFI_SUCCESS. efi_gop = EFI_GRAPHICS_OUTPUT_PROTOCOL *.
     *
     * EFI_GRAPHICS_OUTPUT_PROTOCOL layout (UEFI 2.10 §12.9):
     *   off  0: QueryMode
     *   off  8: SetMode
     *   off 16: Blt
     *   off 24: EFI_GRAPHICS_OUTPUT_PROTOCOL_MODE *Mode
     *
     * EFI_GRAPHICS_OUTPUT_PROTOCOL_MODE:
     *   off  0: UINT32 MaxMode
     *   off  4: UINT32 Mode
     *   off  8: EFI_GRAPHICS_OUTPUT_MODE_INFORMATION *Info
     *   off 16: UINTN SizeOfInfo
     *   off 24: EFI_PHYSICAL_ADDRESS FrameBufferBase (uint64)
     *   off 32: UINTN FrameBufferSize
     *
     * EFI_GRAPHICS_OUTPUT_MODE_INFORMATION:
     *   off  0: UINT32 Version
     *   off  4: UINT32 HorizontalResolution
     *   off  8: UINT32 VerticalResolution
     *   off 12: UINT32 PixelFormat
     *           0 = PixelRedGreenBlueReserved8BitPerColor (RGB)
     *           1 = PixelBlueGreenRedReserved8BitPerColor (BGR)
     *           2 = PixelBitMask
     *           3 = PixelBltOnly (no linear FB, can't render)
     *   off 16: EFI_PIXEL_BITMASK PixelInformation[4 × uint32]
     *   off 32: UINT32 PixelsPerScanLine
     */
    movq    efi_gop(%rip), %rax
    movq    24(%rax), %r10                  /* r10 = ->Mode */
    movq    8(%r10), %r11                   /* r11 = Mode->Info */
    movq    24(%r10), %r12                  /* r12 = FrameBufferBase (u64) */
    movq    32(%r10), %r13                  /* r13 = FrameBufferSize */

    /* Sanity: bail if FrameBufferBase==0 OR PixelFormat==PixelBltOnly
     * (Blt-only modes have no scan-out memory). In either case leave
     * present=0 and skip writing the struct. */
    testq   %r12, %r12
    jz      .Lefi_gop_skip
    movl    12(%r11), %eax                  /* PixelFormat */
    cmpl    $3, %eax                        /* 3 = PixelBltOnly */
    je      .Lefi_gop_skip

    /* Pull the geometry fields into scratch registers. */
    movl    4(%r11), %ecx                   /* HorizontalResolution  */
    movl    8(%r11), %edx                   /* VerticalResolution    */
    movl    12(%r11), %esi                  /* PixelFormat           */
    movl    32(%r11), %edi                  /* PixelsPerScanLine     */

    /* pitch_bytes = PixelsPerScanLine * 4.
     *
     * Per UEFI 2.10 §12.9.2, PixelsPerScanLine is the number of
     * *pixels* in each scanline of the framebuffer's video memory,
     * which may exceed HorizontalResolution because real GPUs pad
     * each scanline to a hardware-friendly stride (typically a
     * multiple of 64 or 128 bytes). Hamnix supports only 32 bpp GOP
     * formats (RGB/BGR with 8-bit reserved channel), so the byte
     * stride is exactly PixelsPerScanLine * 4. Using HorizontalRes
     * here would be the classic GOP renderer bug (a) — every fourth
     * scanline drifts by a few pixels on hardware where PPSL > HRes,
     * which is most real laptops. */
    shll    $2, %edi                        /* pitch_bytes */

    /* Now write the struct. %rax = &efi_fb_info, set up at the top
     * of this block. Layout (matches boot_info_asm.S):
     *   off  0: present       (u32)
     *   off  4: width         (u32)
     *   off  8: height        (u32)
     *   off 12: pitch_bytes   (u32)
     *   off 16: pixel_format  (u32)
     *   off 20: bpp           (u32)
     *   off 24: base          (u64)
     *   off 32: size          (u64)
     */
    movq    efi_kernel_fb_info_ptr(%rip), %rax
    movl    %ecx,  4(%rax)                  /* width                 */
    movl    %edx,  8(%rax)                  /* height                */
    movl    %edi, 12(%rax)                  /* pitch_bytes           */
    movl    %esi, 16(%rax)                  /* pixel_format          */
    movl    $32,  20(%rax)                  /* bpp (constant, GOP)   */
    movq    %r12, 24(%rax)                  /* base                  */
    movq    %r13, 32(%rax)                  /* size                  */
    /* Write `present` LAST so a reader of the struct (post-kernel-boot
     * Adder code) never sees a half-populated record. The kernel
     * is single-threaded at this point — no real concurrency — but
     * the ordering is correct for cheap and future-proof. */
    movl    $1,   0(%rax)                   /* present = 1           */

    leaq    efi_msg_gop_ok(%rip), %rsi
    call    efi_serial_puts
    jmp     .Lefi_gop_done

.Lefi_gop_skip:
    leaq    efi_msg_gop_skip(%rip), %rsi
    call    efi_serial_puts

.Lefi_gop_done:

    /* =================================================================
     * STEP 5+6: GetMemoryMap + ExitBootServices retry loop.
     *
     * Hardened for real-hardware UEFI (M16.157):
     *
     *   - GetMemoryMap's return value is now CHECKED on every iteration.
     *     Previously (M16.111..M16.156) the stub blindly called
     *     ExitBootServices regardless of whether GetMemoryMap succeeded
     *     — fine on OVMF (whose memory map fits in 1.5 KiB and GetMemoryMap
     *     never failed) but catastrophic on the Asus i5-4210U whose
     *     Insyde firmware overflows a 16 KiB buffer with its ~200 96 B
     *     descriptors. EFI_BUFFER_TOO_SMALL leaves MapKey untouched, so
     *     ExitBootServices then fails with EFI_INVALID_PARAMETER, the
     *     retry loop exhausts, the stub halts — silently from a board
     *     with no serial header.
     *
     *   - On GetMemoryMap failure we now print the EFI status code AND
     *     the firmware-requested buffer size on COM1. This is the smoking
     *     gun that turns a "ISO doesn't boot" bug-report into a one-line
     *     "bump EFI_MMAP_BUF_SIZE past N KiB" fix.
     *
     *   - On GetMemoryMap failure we DO NOT proceed to ExitBootServices
     *     with a stale MapKey (would burn through retries for no good
     *     reason). Instead we tag the kernel handoff "map absent" and
     *     halt with an explicit diagnostic.
     *
     *   - On GetMemoryMap success the in-buffer descriptor array is the
     *     basis for both ExitBootServices (its MapKey) AND the kernel's
     *     efi_mmap_info handoff (its descriptor data). The retry path
     *     re-runs GetMemoryMap to get a fresh MapKey if ExitBootServices
     *     rejected the prior one — that re-run also produces a fresh
     *     descriptor array, so the handoff stash after .Lefi_exit_ok
     *     always reflects the map that ExitBootServices accepted.
     *
     * %r15 carries "did the last GetMemoryMap call succeed" across the
     * exit point so the memmap-handoff code below can gate on it. We
     * use %r15 (callee-saved in the SysV ABI, and not clobbered by
     * efi_serial_puts/puthex64) instead of a memory flag so the gate is
     * cheap.
     * ================================================================= */
    movl    $0, %ebx                        /* retry counter */
    xorq    %r15, %r15                      /* r15 = last-GetMemoryMap-OK */

.Lefi_exit_retry:
    /* Always reset the IN/OUT MemoryMapSize to our buffer capacity
     * before each GetMemoryMap call — firmware overwrites it with
     * either the bytes-written count (on success) or the required
     * size (on EFI_BUFFER_TOO_SMALL). */
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

    /* Check GetMemoryMap return value. UEFI 2.10 §7.2.3:
     *   EFI_SUCCESS               (0)  - MapKey + buffer populated
     *   EFI_BUFFER_TOO_SMALL (0x...05) - efi_mmap_size = needed bytes;
     *                                    MapKey UNDEFINED (untouched)
     *   EFI_INVALID_PARAMETER (0x...02)- bogus pointer (we control the
     *                                    pointers — should never happen)
     *
     * Stash success/failure in %r15: 1 = OK, 0 = failed (kernel handoff
     * must be skipped + halt with diagnostic). */
    testq   %rax, %rax
    jnz     .Lefi_mmap_get_failed
    movq    $1, %r15
    jmp     .Lefi_mmap_get_done

.Lefi_mmap_get_failed:
    /* %rax = error EFI_STATUS. efi_mmap_size = firmware-requested size
     * if EFI_BUFFER_TOO_SMALL, else stale. Print both — the size value
     * is the actionable bit for a "bump the buffer" fix.
     *
     * %rax is live across efi_serial_puts (which trashes %rax/%rcx/
     * %rdx/%rsi); stash it in %r14 first. */
    movq    %rax, %r14                      /* save EFI_STATUS */

    leaq    efi_msg_mmap_get_fail_a(%rip), %rsi
    call    efi_serial_puts
    movq    %r14, %rdi                      /* status code */
    call    efi_serial_puthex64
    leaq    efi_msg_mmap_get_fail_b(%rip), %rsi
    call    efi_serial_puts
    movq    efi_mmap_size(%rip), %rdi       /* firmware-needed size */
    call    efi_serial_puthex64
    leaq    efi_msg_mmap_get_fail_c(%rip), %rsi
    call    efi_serial_puts

    /* Cannot recover: without a valid MapKey ExitBootServices will fail.
     * Halt with the diagnostic on serial so a hardware-bring-up bug
     * report can quote the exact required size. The user must enlarge
     * EFI_MMAP_BUF_SIZE past that value and rebuild. */
    jmp     .Lefi_halt

.Lefi_mmap_get_done:
    movq    efi_image_handle(%rip), %rcx
    movq    efi_mmap_key(%rip),     %rdx
    movq    efi_boot_services(%rip), %rax
    movq    232(%rax), %rax                 /* ->ExitBootServices */
    subq    $0x20, %rsp
    call    *%rax
    addq    $0x20, %rsp

    testq   %rax, %rax
    jz      .Lefi_exit_ok

    /* ExitBootServices rejected the MapKey (typically because firmware
     * allocated between GetMemoryMap and here, invalidating it). Bound
     * the retry — on each iteration we re-call GetMemoryMap to grab a
     * fresh MapKey (and a fresh descriptor array, which the kernel
     * handoff downstream wants anyway). */
    xorq    %r15, %r15                      /* clear: this iter's map is stale */
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
     * Hand the EFI memory map to the kernel (M16.155).
     *
     * The last GetMemoryMap call above (the one whose MapKey
     * ExitBootServices accepted) wrote the LIVE descriptor array into
     * efi_mmap_buf with:
     *   efi_mmap_size      = total bytes written
     *   efi_mmap_descsize  = stride of one EFI_MEMORY_DESCRIPTOR
     *   efi_mmap_descver   = revision tag (always 1 today)
     *
     * Stash the buffer's RUNTIME address + the three sizes into the
     * kernel's efi_mmap_info struct. The kernel then walks the
     * descriptors in e820_init() to unlock every byte of usable RAM
     * the firmware advertised (replaces the conservative 2..240 MiB
     * fallback that capped RAM on UEFI boots).
     *
     * The descriptor buffer lives in this stub's .bss — i.e. inside
     * the EfiLoaderCode/Data region firmware allocated for our image.
     * That memory is NOT reclaimed by firmware after ExitBootServices
     * and is deliberately excluded from memblock's free pool by the
     * walker (only EfiConventionalMemory + EfiBootServicesCode/Data
     * are pulled in), so the pointer remains live for the kernel's
     * lifetime — long enough to consume during e820_init().
     *
     * Layout (matches boot_info_asm.S efi_mmap_info):
     *   off  0: present       (u32)
     *   off  4: desc_size     (u32)
     *   off  8: buf_phys      (u64)
     *   off 16: size_bytes    (u64)
     *   off 24: desc_version  (u32)
     *   off 28: _reserved     (u32)
     *   off 32: _reserved64   (u64)
     *
     * Write `present` LAST so a reader can never see a half-populated
     * record. The kernel is single-threaded at this point so the
     * ordering is mostly self-documenting, but cheap and correct.
     *
     * Two skip-paths land at .Lefi_mmap_handoff_skip:
     *   (a) kernel handoff table has no +68 slot (pre-M16.155 kernel).
     *       efi_kernel_mmap_info_ptr is zero; %r10 == 0 after the load.
     *   (b) the last GetMemoryMap before the successful ExitBootServices
     *       did NOT succeed (only possible today via a path we explicitly
     *       reject above, but the gate is cheap defence-in-depth and
     *       documents the invariant: "present=1 implies efi_mmap_buf
     *       contains the descriptor array ExitBootServices accepted").
     *       %r15 == 0 on this path.
     *
     * In both skip cases the kernel's e820_init falls back to the
     * conservative 2..240 MiB window (e820.ad EFI_FALLBACK_* — still
     * enough to bring up hamsh, just no >240 MiB RAM unlock). */
    movq    efi_kernel_mmap_info_ptr(%rip), %r10
    testq   %r10, %r10
    jz      .Lefi_mmap_handoff_skip         /* old kernel, no +68 slot */
    testq   %r15, %r15
    jz      .Lefi_mmap_handoff_skip         /* last GetMemoryMap not OK */

    /* desc_size (u32) */
    movq    efi_mmap_descsize(%rip), %rax
    movl    %eax, 4(%r10)

    /* buf_phys = runtime address of efi_mmap_buf (u64) */
    leaq    efi_mmap_buf(%rip), %rax
    movq    %rax, 8(%r10)

    /* size_bytes (u64) */
    movq    efi_mmap_size(%rip), %rax
    movq    %rax, 16(%r10)

    /* desc_version (u32) */
    movq    efi_mmap_descver(%rip), %rax
    movl    %eax, 24(%r10)

    /* present = 1 — LAST. */
    movl    $1, 0(%r10)

    leaq    efi_msg_mmap_ok(%rip), %rsi
    call    efi_serial_puts
    jmp     .Lefi_mmap_handoff_done

.Lefi_mmap_handoff_skip:
    leaq    efi_msg_mmap_skip(%rip), %rsi
    call    efi_serial_puts

.Lefi_mmap_handoff_done:

    /* =================================================================
     * STEP 8: Build identity-mapped page tables (1 GiB pages, 512 GiB).
     * Mirrors arch/x86/boot/header.S's PML4[0]->PDPT arrangement but
     * stamps the FULL 512-entry PDPT instead of just the first 4 — the
     * pre-M16.152 4-GiB window left Asus UEFI allocs above 4 GiB
     * unmapped, which silent-hung real hardware (M16.151 diagnostic
     * confirmed pdpt[4..7]=0 at the smoking-gun moment). Tables live
     * in this stub's .bss (efi_pml4 / efi_pdpt — 4 KiB aligned via
     * .align 4096; efi_pdpt is exactly 4 KiB = 512*8 B so the full
     * loop never overruns the page).
     *
     * PML4[0] = &efi_pdpt | (RW | P) = &efi_pdpt | 0x3
     * PDPT[i] = (i << 30) | (PS | US | RW | P) = (i << 30) | 0x87
     *          for i in [0, 512).
     *
     * NOTE on US=1: header.S sets US=1 (0x87) on its 4 GiB stamp, and
     *       arch/x86/mm/pgtable.ad's PGT_NEW_FLAGS = 0x87 matches that
     *       when extending the map past 4 GiB on the multiboot path.
     *       We use the same flags here so all three sites agree.
     *       The kernel runs at CPL=0 either way — US=1 is a no-op for
     *       supervisor accesses but lets identity-mapped CPL=3
     *       instruction fetches resolve when a user task lands above
     *       4 GiB (see the long comment in pgtable.ad on why ET_DYN
     *       user binaries share the BSP PML4 today).
     * ================================================================= */
    leaq    efi_pdpt(%rip), %rax
    orq     $0x7, %rax
    leaq    efi_pml4(%rip), %rdi
    movq    %rax, (%rdi)

    /* ----- Higher-half kernel mapping (PML4[511]) -------------------
     * The kernel proper is LINKED at 0xffffffff80000000+offset. Its
     * PT_LOAD segments were just copied to their LOW p_paddr above.
     * To run the kernel at its high link-time VMA we map PML4[511]
     * (covers 0xffffff8000000000..top) at a fresh PDPT, then stamp
     * that PDPT's entries 510 and 511 as 1 GiB pages at physical 0
     * and 1 GiB. That makes 0xffffffff80000000 -> phys 0, so the
     * kernel's VMA 0xffffffff80000000+offset resolves to phys
     * 0+offset == the LMA the PT_LOAD copy targeted.
     *
     *   0xffffffff80000000: PML4 idx 511, PDPT idx 510
     *   0xffffffffc0000000: PML4 idx 511, PDPT idx 511
     *
     * PML4 slot 511 is at byte offset 511*8 = 0xFF8. */
    leaq    efi_pdpt_high(%rip), %rax
    orq     $0x7, %rax                      /* US|RW|P */
    leaq    efi_pml4(%rip), %rdi
    movq    %rax, 0xFF8(%rdi)               /* PML4[511] -> efi_pdpt_high */

    /* efi_pdpt_high[510] -> 1 GiB page @ phys 0
     * efi_pdpt_high[511] -> 1 GiB page @ phys 1 GiB
     * Flags 0x87 = PS|US|RW|P (matches header.S pdpt_high). */
    leaq    efi_pdpt_high(%rip), %rdi
    movq    $0x87, %rax                     /* PS|US|RW|P, phys 0 */
    movq    %rax, (510 * 8)(%rdi)
    movq    $0x40000087, %rax               /* PS|US|RW|P, phys 1 GiB */
    movq    %rax, (511 * 8)(%rdi)

    /* PDPT entries 0..511: 1 GiB pages spanning [0, 512 GiB).
     *
     * M16.152 (Asus UEFI real-hw fix): the prior version of this loop
     * stamped only PDPT[0..3], covering [0, 4 GiB). On QEMU `-m 256M`
     * that's fine (every alloc lands below 4 GiB), but Asus firmware
     * lays out the EFI memory map so that kernel allocations land at
     * e.g. 0x100404000 — above 4 GiB. The M16.151 diagnostic
     * ("[pgtable] EFI/no-mb: pdpt[4..7]=0") confirmed those slots
     * were unmapped at the moment of the silent hang; the first kernel
     * store into the above-4-GiB allocation traps #PF with no
     * productive handler in early boot, the CPU triple-faults, and
     * the firmware resets — "silent" from the serial console.
     *
     * Fix: extend the stamp to fill all 512 PDPT entries up front.
     * 512 * 8 B = 4 KiB, exactly the size of the efi_pdpt page in
     * .bss; firmware NOBITS-zeroes the page at image-map time so any
     * untouched bytes would have been 0 (i.e. P=0, unmapped) anyway.
     * The cost is one tight 512-iteration loop at boot, well under a
     * microsecond. Same flags as the prior 4-entry stamp
     * (0x87 = PS|US|RW|P) — matches header.S and pgtable.ad's
     * PGT_NEW_FLAGS so a side-by-side diff is clean.
     *
     * Linux's early boot does the same thing (arch/x86/kernel/head_64.S
     * level5_kernel_pgt / level4_kernel_pgt fill the full PDPT for
     * the kernel half of the address space); we mirror the pattern. */
    leaq    efi_pdpt(%rip), %rdi
    movq    $0x87, %rax                     /* PS|US|RW|P, phys=0 */
    movq    $512, %rcx                      /* loop counter */
1:
    movq    %rax, (%rdi)
    addq    $0x40000000, %rax               /* next 1 GiB phys base */
    addq    $8, %rdi                        /* next PDPT slot */
    decq    %rcx
    jnz     1b

    /* Debug marker: page tables built. */
    leaq    efi_msg_pgtab(%rip), %rsi
    call    efi_serial_puts

    /* =================================================================
     * STEP 9: Load the kernel's own gdt64 (M16.126 fix).
     *
     * History (M16.111..M16.125): this stub used to load a private
     * 3-entry GDT (efi_gdt: null, k-cs=0x08, k-ds=0x10). That works
     * for the far-jump-to-flush-CS step below, but it leaves the
     * GDT limit at 23 bytes — selectors 0x18 (user DS), 0x20 (user
     * CS), and 0x28 (TSS) all index past the limit and #GP the next
     * instruction that loads them. In the BIOS multiboot path none of
     * that matters because header.S's gdt64 has 7 entries already.
     * In the EFI path, tss_init's `ltr $0x28` was the first such
     * load — it trapped #GP err=0x28 right after `syscall MSRs armed`
     * in init/main.ad, never reaching start_first_task.
     *
     * The fix is to load the kernel's own gdt64 (whose address we
     * pulled out of the handoff table's +60 slot above). gdt64 has
     * 7 quads = 56 bytes, so the limit is 55 = 0x37. We build a
     * fresh 10-byte (m16:64) gdtr descriptor here at runtime because
     * the kernel's gdt64_descriptor is 6 bytes (m16:32, for the
     * 32-bit-protected-mode lgdt in header.S) — wrong shape for a
     * 64-bit lgdt.
     * ================================================================= */
    movw    $0x37, efi_kgdt_descriptor_limit(%rip)   /* 56 - 1 */
    movl    efi_kernel_gdt_addr(%rip), %eax          /* &gdt64 (uint32) */
    movq    %rax, efi_kgdt_descriptor_base(%rip)     /* zero-extend to 64-bit */
    lgdt    efi_kgdt_descriptor(%rip)

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

    /* Jump to _x86_start_after_loader — the LOW UEFI entry shim in
     * arch/x86/boot/header.S (.boot.text). efi_kernel_entry holds its
     * address from the +52 handoff slot; the shim lives in the LOW
     * boot region (VMA ~0x10xxxx), reachable through efi_pdpt's
     * identity map. The shim's only job is to movabsq-jump up to the
     * higher-half kernel head — and STEP 8's efi_pdpt_high makes that
     * high-half target mapped. */
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


/* efi_serial_puthex64:
 *   %rdi = 64-bit value to render as 16 ASCII hex digits ("0x" prefix
 *          NOT emitted — caller is expected to print the literal "0x"
 *          out of an .rdata string so the prefix can vary).
 *   Trashes: %rax, %rcx, %rdx, %rsi, %rdi
 *
 * Used by the GetMemoryMap failure path to surface the EFI_STATUS code
 * and the firmware-requested buffer size on the COM1 serial console.
 * Sixteen always-fixed-width digits keeps the log line aligned across
 * runs — easy to grep, easy to eyeball.
 *
 * Algorithm: walk the nibble shift count from 60 down to 0 in steps of
 * 4 (most-significant first), mask off the low 4 bits, map 0..9 -> '0'..'9'
 * and 10..15 -> 'a'..'f', then funnel through the per-byte UART
 * THR-wait loop. */
efi_serial_puthex64:
    movl    $60, %ecx                       /* shift count: 60, 56, ..., 0 */
.Lputhex_next:
    movq    %rdi, %rax
    shrq    %cl, %rax
    andl    $0x0F, %eax                     /* nibble */
    cmpl    $10, %eax
    jb      .Lputhex_digit
    addl    $('a' - '0' - 10), %eax
.Lputhex_digit:
    addl    $'0', %eax                      /* %al = ASCII hex char */

    /* Stash the digit in %sil (low byte of %rsi — clobbered per the
     * documented ABI of this helper) before the LSR-poll loop, because
     * `inb` writes to %al and would otherwise overwrite the digit. */
    movb    %al, %sil

    /* Poll LSR bit 5 (THR empty) before writing the byte. */
    movw    $0x3FD, %dx
.Lputhex_wait:
    inb     %dx, %al
    testb   $0x20, %al
    jz      .Lputhex_wait

    /* THR empty — restore the digit from %sil and emit it on COM1. */
    movb    %sil, %al
    movw    $0x3F8, %dx
    outb    %al, %dx

    subl    $4, %ecx                        /* next nibble */
    jns     .Lputhex_next                   /* until ecx underflows (-4) */
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
efi_msg_gop_ok:
    .asciz  "[hamnix] EFI: GOP captured\r\n"
efi_msg_gop_skip:
    .asciz  "[hamnix] EFI: GOP unavailable (skipped)\r\n"
efi_msg_mmap_ok:
    .asciz  "[hamnix] EFI: memory map handed off\r\n"
efi_msg_mmap_skip:
    .asciz  "[hamnix] EFI: kernel has no efi_mmap_info slot (skipped)\r\n"
    /* M16.157: dense diagnostic for the "Asus boots GRUB instead of
     * Hamnix" bug. Printed as three glued fragments so we can splice
     * the EFI_STATUS code and the firmware-requested byte count between
     * them via efi_serial_puthex64. The full line ends up like
     *
     *   [hamnix] EFI: GetMemoryMap FAILED status=0x8000000000000005 needs=0x00000000000064b8 bytes; halt
     *
     * The "needs=" value is the actionable bit: if firmware wants more
     * than EFI_MMAP_BUF_SIZE, bump the constant past it and rebuild. */
efi_msg_mmap_get_fail_a:
    .asciz  "[hamnix] EFI: GetMemoryMap FAILED status=0x"
efi_msg_mmap_get_fail_b:
    .asciz  " needs=0x"
efi_msg_mmap_get_fail_c:
    .asciz  " bytes; halt\r\n"

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

    /* EFI_GRAPHICS_OUTPUT_PROTOCOL_GUID:
     *   9042a9de-23dc-4a38-96fb-7aded080516a   (UEFI 2.10 §12.9) */
    .align 8
gop_guid:
    .long   0x9042a9de
    .short  0x23dc
    .short  0x4a38
    .byte   0x96, 0xfb, 0x7a, 0xde, 0xd0, 0x80, 0x51, 0x6a

    /* UCS-2 path to the kernel ELF on the ESP. Backslash-separated,
     * NUL-terminated. Each ASCII char is followed by a zero byte for
     * the high half of the UCS-2 unit. */
kernel_path_w:
    .short  '\\', 'h', 'a', 'm', 'n', 'i', 'x', '-'
    .short  'k', 'e', 'r', 'n', 'e', 'l', '.', 'e'
    .short  'l', 'f', 0

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
    /* Direct-stream ELF loader scratch (see STEP 4 rewrite). Both are
     * IN/OUT byte counts for File->Read; tiny, in .data, never aliased
     * by the kernel's LOW load region. */
efi_hdr_read_size:          .quad 0         /* header+phdr read: IN cap / OUT bytes */
efi_seg_read_size:          .quad 0         /* per-segment read: IN filesz / OUT bytes */
efi_seg_remaining:          .quad 0         /* chunked seg read: bytes still owed */
efi_seg_bufptr:             .quad 0         /* chunked seg read: current dst phys ptr */
    /* Address of _x86_start_after_loader pulled out of the kernel's
     * handoff table (planted by arch/x86/boot/header.S). Stored as a
     * uint32 because the kernel is elf32-i386 (VMAs < 4 GiB). */
    .globl efi_kernel_entry
efi_kernel_entry:           .long 0
    /* Address of the kernel's `gdt64` (M16.126), also a uint32. We use
     * it to build a 10-byte gdtr descriptor at runtime — see
     * efi_kgdt_descriptor below. The stub's pre-M16.126 private
     * efi_gdt covered only selectors 0x00/0x08/0x10, which #GPed
     * the kernel's tss_init when it loaded selector 0x28. */
    .globl efi_kernel_gdt_addr
efi_kernel_gdt_addr:        .long 0

    /* GDT descriptor (limit + base). Lives in .data because the
     * 8-byte base is runtime-patched in efi_main (PE/COFF has no
     * .reloc, so the link-time `efi_gdt` value is not the VMA).
     *
     * Pre-M16.126: this was the descriptor actually loaded via lgdt.
     * Kept for now (zero cost) so that any out-of-tree consumers
     * that referenced the symbols don't fail to link; the live code
     * path now uses efi_kgdt_descriptor below. */
    .align 8
    .globl efi_gdt_descriptor
efi_gdt_descriptor:
    .short  efi_gdt_end - efi_gdt - 1       /* limit (constant) */
    .globl efi_gdt_descriptor_base
efi_gdt_descriptor_base:    .quad 0         /* base (runtime-patched) */

    /* M16.126: kernel-GDT descriptor (m16:64). limit and base are
     * both runtime-patched in step 9 of efi_main:
     *   limit = 55 = 0x37 (gdt64 has 7 entries × 8 bytes - 1)
     *   base  = &gdt64 (zero-extended from the uint32 in
     *           efi_kernel_gdt_addr, since the kernel's VMAs are
     *           all < 4 GiB).
     *
     * Has to be a full 10-byte (m16:64) descriptor because we lgdt
     * from 64-bit code — the kernel's own gdt64_descriptor in
     * header.S is m16:32 (used from 32-bit protected mode) and would
     * pull garbage into the upper 32 bits of base if loaded here. */
    .align 8
    .globl efi_kgdt_descriptor
efi_kgdt_descriptor:
    .globl efi_kgdt_descriptor_limit
efi_kgdt_descriptor_limit:  .short 0        /* runtime-patched: 0x37 */
    .globl efi_kgdt_descriptor_base
efi_kgdt_descriptor_base:   .quad 0         /* runtime-patched: &gdt64 */

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

    /* GOP capture state (M16.149).
     *
     * efi_gop: Interface pointer returned by LocateProtocol — pointer to
     *          an EFI_GRAPHICS_OUTPUT_PROTOCOL struct in firmware memory.
     *          We dereference it once to read Mode->{Info, FrameBufferBase,
     *          FrameBufferSize} before ExitBootServices invalidates it.
     *
     * efi_kernel_fb_info_ptr: Address of the kernel's efi_fb_info struct
     *          (in arch/x86/kernel/boot_info_asm.S .data). The stub reads
     *          this from handoff slot +64 and writes the captured GOP
     *          geometry there. Stored as uint64 to match the pointer-
     *          register dereference shape used later. */
    .align 8
    .globl efi_gop
efi_gop:                    .quad 0
    .globl efi_kernel_fb_info_ptr
efi_kernel_fb_info_ptr:     .quad 0
    /* M16.155: Address of the kernel's `efi_mmap_info` struct (in
     * arch/x86/kernel/boot_info_asm.S .boot.data). Pulled from the +68
     * handoff slot. After ExitBootServices the stub stashes the EFI
     * memory-map descriptor pointer + sizes here so e820_init() can
     * walk the descriptors and unlock RAM > 240 MiB on UEFI boots. */
    .globl efi_kernel_mmap_info_ptr
efi_kernel_mmap_info_ptr:   .quad 0
    /* #171: Address of the kernel's `efi_rt_info` struct (in
     * arch/x86/kernel/boot_info_asm.S .boot.data). Pulled from the +72
     * handoff slot. The stub stashes the EFI_SYSTEM_TABLE +
     * RuntimeServices + ConfigurationTable pointers here so the kernel
     * can call GetTime / GetVariable / SetVariable after boot. */
    .globl efi_kernel_rt_info_ptr
efi_kernel_rt_info_ptr:     .quad 0

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

    /* ELF header + program-header table staging buffer. Lives in this
     * stub's .bss (firmware-loaded image region, far above the kernel's
     * fixed-LOW load region [0x100000, load_hi)), so a segment stream to
     * a low p_paddr can never alias/overwrite the phdr table we walk. */
    .align 16
    .globl efi_hdr_buf
efi_hdr_buf:
    .skip ELF_HDR_BUF_SIZE

    .align 4096
    .globl efi_pml4
efi_pml4:
    .skip 4096
    .globl efi_pdpt
efi_pdpt:
    .skip 4096
    /* efi_pdpt_high: the PDPT for PML4[511], the higher-half kernel
     * mapping. Entries 510/511 are stamped as 1 GiB pages in STEP 8 so
     * 0xffffffff80000000 resolves to physical 0. The rest stay P=0
     * (firmware NOBITS-zeroes the page). 4 KiB aligned (page-table
     * granularity). */
    .globl efi_pdpt_high
efi_pdpt_high:
    .skip 4096
