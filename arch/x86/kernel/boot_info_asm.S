/*
 * arch/x86/kernel/boot_info_asm.S - accessors for the multiboot
 * info pointer stashed by the boot stub, plus EFI GOP framebuffer
 * info stashed by the UEFI stub.
 *
 * header.S's 32-bit entry path saves the multiboot magic (EAX) and
 * info pointer (EBX) into two .long slots in the LOW boot region
 * (.boot.data):
 *      .globl mb_magic
 *      mb_magic: .long 0
 *      .globl mb_info
 *      mb_info:  .long 0
 *
 * On the UEFI path (arch/x86/boot/efi_stub.S), the stub queries the
 * EFI_GRAPHICS_OUTPUT_PROTOCOL via BootServices->LocateProtocol BEFORE
 * ExitBootServices() and stores the framebuffer geometry into the
 * efi_fb_info struct defined below. The stub finds this struct via
 * the handoff table's +64 slot in header.S's multiboot header. After
 * ExitBootServices(), boot-services calls (including LocateProtocol)
 * are no longer legal, so this is the only place we can capture GOP.
 *
 * Hamnix currently has no "extern variable" syntax, so we read those
 * symbols out via tiny accessor functions instead.
 *
 * HIGHER-HALF NOTE: mb_magic / mb_info / boot_via_efi / efi_fb_info
 * all live in the LOW boot region (.boot.data, VMA ~0x10xxxx) so the
 * 32-bit boot stub and the EFI handoff table can reference them with
 * 32-bit addresses. THIS file's code is linked in the higher half
 * (0xffffffff80...). A RIP-relative `leaq sym(%rip)` from high code to
 * a low boot symbol would overflow the ±2 GiB PC-relative
 * displacement, so every accessor below materialises the absolute
 * address with `movabsq $sym` (an R_X86_64_64 relocation — valid now
 * that the kernel links as a true elf64-x86-64 object). The multiboot
 * info struct and the EFI framebuffer base may be anywhere in 64-bit
 * RAM, hence the 64-bit-clean loads.
 */

    .code64
    .section .text, "ax"

    .align 16
    .globl get_mb_magic
get_mb_magic:
    movabsq $mb_magic, %rax
    movl    (%rax), %eax              /* movl zero-extends to %rax  */
    ret

    .align 16
    .globl get_mb_info
get_mb_info:
    movabsq $mb_info, %rax
    movl    (%rax), %eax
    ret

    /* ---- boot_via_efi accessors ---------------------------------------
     *
     * boot_via_efi is a LOW-boot-region int32 flag (.boot.data),
     * default 0. The EFI stub patches it to 1 via the +56 handoff
     * slot before jumping to the kernel; arch/x86/kernel/e820.ad reads
     * it through get_boot_via_efi() and can also set it via
     * set_boot_via_efi_asm() (kept for the documented future API). */
    .align 16
    .globl get_boot_via_efi
get_boot_via_efi:
    movabsq $boot_via_efi, %rax
    movl    (%rax), %eax
    ret

    .align 16
    .globl set_boot_via_efi_asm
set_boot_via_efi_asm:
    movabsq $boot_via_efi, %rax
    movl    $1, (%rax)
    ret

    /* ---- EFI GOP framebuffer accessors --------------------------------
     *
     * efi_fb_info layout (.boot.data, populated by arch/x86/boot/
     * efi_stub.S right before ExitBootServices; zero on multiboot1):
     *
     *   off  0: uint32 present       (1 = populated, 0 = no GOP)
     *   off  4: uint32 width         (HorizontalResolution)
     *   off  8: uint32 height        (VerticalResolution)
     *   off 12: uint32 pitch_bytes   (PixelsPerScanLine × bytes_per_px)
     *   off 16: uint32 pixel_format  (0 RGB, 1 BGR, 2 BitMask, 3 Blt)
     *   off 20: uint32 bpp           (always 32 today)
     *   off 24: uint64 base          (FrameBufferBase — may be > 4 GiB)
     *   off 32: uint64 size          (FrameBufferSize)
     *
     * Total: 40 bytes. The efi_stub.S writes the whole struct in one
     * pass via offset stores from a base register pointing here.
     */
    .align 16
    .globl get_efi_fb_present
get_efi_fb_present:
    movabsq $efi_fb_info, %rax
    movl    0(%rax), %eax
    ret

    .align 16
    .globl get_efi_fb_width
get_efi_fb_width:
    movabsq $efi_fb_info, %rax
    movl    4(%rax), %eax
    ret

    .align 16
    .globl get_efi_fb_height
get_efi_fb_height:
    movabsq $efi_fb_info, %rax
    movl    8(%rax), %eax
    ret

    .align 16
    .globl get_efi_fb_pitch_bytes
get_efi_fb_pitch_bytes:
    movabsq $efi_fb_info, %rax
    movl    12(%rax), %eax
    ret

    .align 16
    .globl get_efi_fb_pixel_format
get_efi_fb_pixel_format:
    movabsq $efi_fb_info, %rax
    movl    16(%rax), %eax
    ret

    .align 16
    .globl get_efi_fb_bpp
get_efi_fb_bpp:
    movabsq $efi_fb_info, %rax
    movl    20(%rax), %eax
    ret

    /* base + size are 64-bit. Caller gets the full 64-bit value. */
    .align 16
    .globl get_efi_fb_base
get_efi_fb_base:
    movabsq $efi_fb_info, %rcx
    movq    24(%rcx), %rax
    ret

    .align 16
    .globl get_efi_fb_size
get_efi_fb_size:
    movabsq $efi_fb_info, %rcx
    movq    32(%rcx), %rax
    ret

    /* ---- EFI memory-map accessors -------------------------------------
     *
     * efi_mmap_info is a kernel-side .boot.data record populated by the
     * UEFI stub (arch/x86/boot/efi_stub.S) right BEFORE ExitBootServices.
     * The stub locates this struct via handoff slot +68 in header.S's
     * multiboot header. Once populated, the kernel can walk the firmware
     * memory map (EFI_MEMORY_DESCRIPTOR records at buf_phys) to discover
     * every byte of usable RAM the firmware advertised — instead of
     * falling back to the conservative 2..240 MiB hardcoded window.
     *
     * Layout (40 bytes — keep wide for forward-compatibility):
     *
     *   off  0: uint32 present          (1 = populated, 0 = no EFI map)
     *   off  4: uint32 desc_size        (EFI_MEMORY_DESCRIPTOR stride —
     *                                    NOT necessarily 48; firmware
     *                                    can pad it for future ABI
     *                                    extensions)
     *   off  8: uint64 buf_phys         (descriptor array, physical addr
     *                                    inside the stub's loader image,
     *                                    identity-mapped so the kernel
     *                                    can deref directly)
     *   off 16: uint64 size_bytes       (total descriptor-array size;
     *                                    entry count = size_bytes /
     *                                    desc_size)
     *   off 24: uint32 desc_version     (revision tag from firmware;
     *                                    currently always 1)
     *   off 28: uint32 _reserved        (alignment + room for future
     *                                    flags without churning the
     *                                    handoff ABI)
     *   off 32: uint64 _reserved64
     *
     * Zero on every BIOS / multiboot1 boot — boot.data starts zeroed and
     * only the UEFI stub touches this region. get_efi_mmap_present()
     * returning 0 is the well-defined "no EFI map" signal.
     */
    .align 16
    .globl get_efi_mmap_present
get_efi_mmap_present:
    movabsq $efi_mmap_info, %rax
    movl    0(%rax), %eax
    ret

    .align 16
    .globl get_efi_mmap_desc_size
get_efi_mmap_desc_size:
    movabsq $efi_mmap_info, %rax
    movl    4(%rax), %eax
    ret

    .align 16
    .globl get_efi_mmap_buf_phys
get_efi_mmap_buf_phys:
    movabsq $efi_mmap_info, %rcx
    movq    8(%rcx), %rax
    ret

    .align 16
    .globl get_efi_mmap_size_bytes
get_efi_mmap_size_bytes:
    movabsq $efi_mmap_info, %rcx
    movq    16(%rcx), %rax
    ret

    .align 16
    .globl get_efi_mmap_desc_version
get_efi_mmap_desc_version:
    movabsq $efi_mmap_info, %rax
    movl    24(%rax), %eax
    ret

    /* ---- EFI GOP framebuffer storage ----------------------------------
     *
     * Lives in .boot.data (the LOW boot region) so the EFI handoff
     * table's 32-bit +64 slot can carry its address and the EFI stub
     * can write it by that low physical address before jumping to the
     * kernel. .boot.data is loaded zero-initialised; BIOS multiboot1
     * boot never touches this region (`present` stays 0 and the Adder
     * accessor short-circuits).
     */
    .section .boot.data, "aw"
    .align 8
    .globl efi_fb_info
efi_fb_info:
    .long 0     /* off  0 present       */
    .long 0     /* off  4 width         */
    .long 0     /* off  8 height        */
    .long 0     /* off 12 pitch_bytes   */
    .long 0     /* off 16 pixel_format  */
    .long 0     /* off 20 bpp           */
    .quad 0     /* off 24 base (uint64) */
    .quad 0     /* off 32 size (uint64) */

    /* ---- EFI memory-map handoff storage --------------------------------
     *
     * Sibling of efi_fb_info: 40 bytes of kernel-side .boot.data populated
     * by arch/x86/boot/efi_stub.S right before ExitBootServices. The stub
     * locates this struct via handoff slot +68 in the multiboot header
     * (arch/x86/boot/header.S) — a 32-bit address suffices because every
     * symbol referenced from the handoff table lives in the LOW boot
     * region (.boot.data).
     *
     * The actual descriptor array is NOT copied here. The stub points
     * buf_phys at the descriptors as they sit in its own .bss
     * (efi_mmap_buf, ~16 KiB). After ExitBootServices that memory is
     * still allocated to the loaded EFI image (EfiLoaderCode/Data
     * regions) — firmware will not reclaim it, and our identity map
     * covers all 512 GiB, so the kernel can dereference buf_phys
     * directly. We deliberately do NOT include EfiLoaderCode/Data in
     * the memblock-free pool, so the stub's image (and its EFI mmap
     * scratch) stays unreserved-from-overwrite.
     */
    .align 8
    .globl efi_mmap_info
efi_mmap_info:
    .long 0     /* off  0 present              */
    .long 0     /* off  4 desc_size (stride)   */
    .quad 0     /* off  8 buf_phys             */
    .quad 0     /* off 16 size_bytes           */
    .long 0     /* off 24 desc_version         */
    .long 0     /* off 28 _reserved            */
    .quad 0     /* off 32 _reserved64          */
