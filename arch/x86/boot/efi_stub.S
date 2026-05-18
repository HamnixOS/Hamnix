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
 * (we assume) boot services either still active or already exited by a
 * caller — for the stub's current purposes it doesn't matter, because
 * the stub does nothing but print a marker and halt.
 *
 * What this stub does today (M16.70 stage 1):
 *   1. Receive EFI_HANDLE in %rcx, EFI_SYSTEM_TABLE* in %rdx (Microsoft
 *      x64 calling convention, per UEFI Specification 2.x §2.3.4).
 *   2. Stash both into well-known globals (efi_image_handle / efi_system_table)
 *      so a future kernel handoff can pull them back.
 *   3. Write the literal ASCII marker "[hamnix] EFI entry reached\r\n" to
 *      the 16550A UART at COM1 / port 0x3F8. UEFI does not claim port I/O
 *      so we can talk to the legacy UART directly; this is also how the
 *      QEMU `-serial stdio` test capture sees it.
 *   4. Halt forever (cli; hlt; jmp $-).
 *
 * What this stub deliberately does NOT do yet (follow-up commits):
 *   - Parse the embedded kernel ELF and copy PT_LOAD segments to their
 *     physical addresses. The full kernel handoff path is the next step
 *     once this stage proves PE/COFF parsing works on real UEFI firmware.
 *   - Call ExitBootServices() / SetVirtualAddressMap(). Today we assume
 *     the caller did so, or that firmware tolerates us not doing it.
 *   - Talk to ConOut. Firmware-mode console output is convenient but adds
 *     a TableProtocol indirection we don't need to prove "PE entry reached."
 *
 * Build:
 *   The Hamnix compiler still emits ELF for the multiboot1 kernel image.
 *   This file is assembled with `as --64` (true 64-bit elf64-x86-64) and
 *   linked with `ld -m i386pep --subsystem 10` to produce a true PE32+
 *   EFI_APPLICATION. See scripts/build_iso.sh for the exact invocation.
 *   Two separate output binaries — see docs/BOOT.md for why.
 */

    .code64
    .section .text, "ax"

    .globl  efi_main
efi_main:
    /* Microsoft x64 calling convention:
     *   %rcx = EFI_HANDLE       ImageHandle
     *   %rdx = EFI_SYSTEM_TABLE *SystemTable
     * UEFI doesn't expect a frame; we stash both before doing anything
     * else so a later kernel handoff can pull them back. */
    cli
    movq    %rcx, efi_image_handle(%rip)
    movq    %rdx, efi_system_table(%rip)

    /* Anchor a stack of our own. UEFI provides a stack but the size is
     * implementation-defined (typically 128 KiB on edk2 OVMF); switching
     * to our own keeps later kernel handoff straightforward and gives us
     * a known 16 KiB region. The PE linker puts efi_stub_stack_top in
     * .bss, page-aligned. */
    leaq    efi_stub_stack_top(%rip), %rsp

    /* Print "[hamnix] EFI entry reached\r\n" over COM1.
     *
     * Why bare port I/O instead of UEFI ConOut:
     *   - No EFI_BOOT_SERVICES indirection (one fewer thing to debug if
     *     firmware misbehaves).
     *   - The test harness reads serial via `-serial stdio`; ConOut
     *     output goes to OVMF's video framebuffer by default, not stdio.
     *   - Real hardware: a serial cable on COM1 is the canonical
     *     headless-bringup channel. ConOut might be GOP-only.
     *
     * UEFI does NOT claim port I/O, and OVMF leaves the 16550A alive at
     * its standard ISA address (DLAB programming etc. from the firmware
     * leaves baud + line control in a usable state). If a real board
     * disabled the UART we'd see no output, but no harm — kernel halt
     * still happens.
     *
     * 16550A register layout at 0x3F8:
     *   0x3F8 THR / RBR  (transmit / receive)
     *   0x3FD LSR        (line status — bit 5 = THR empty)
     */
    leaq    efi_marker_msg(%rip), %rsi
    call    efi_serial_puts

    /* Halt forever. Future commits replace this with the kernel handoff. */
1:  cli
    hlt
    jmp     1b

    .globl  efi_main_end
efi_main_end:


/* efi_serial_puts:
 *   %rsi = pointer to NUL-terminated ASCII string
 *   Trashes: %rax, %rcx, %rdx, %rsi (caller-saved under MS x64)
 *
 * Writes each byte to port 0x3F8 after polling LSR bit 5 (THR empty).
 * Tight loop — no timeout. If the UART is dead this hangs, but the
 * outer code halts the CPU anyway and a hung CPU after a dead UART
 * is the same observable state on real hardware (silent box). */
efi_serial_puts:
    movw    $0x3F8, %dx
.Lputs_next:
    movb    (%rsi), %al
    testb   %al, %al
    jz      .Lputs_done
    /* Wait for THR empty (LSR bit 5). */
    movw    $0x3FD, %dx
.Lputs_wait:
    inb     %dx, %al
    testb   $0x20, %al
    jz      .Lputs_wait
    /* Restore the byte to send — inb clobbered %al. */
    movb    (%rsi), %al
    movw    $0x3F8, %dx
    outb    %al, %dx
    incq    %rsi
    jmp     .Lputs_next
.Lputs_done:
    ret


/* ---------- Read-only data --------------------------------------- */
    .section .rdata, "a"
    .align 8
efi_marker_msg:
    .asciz  "[hamnix] EFI entry reached\r\n"


/* ---------- Writable data --------------------------------------- *
 * Stashed firmware handoff state. Currently the EFI stub halts so
 * nothing reads these back, but exposing them as globals means a
 * follow-up commit (real kernel handoff) can pick them up without
 * threading them through %rcx/%rdx by hand. */
    .section .data, "aw"
    .align 8
    .globl efi_image_handle
efi_image_handle:
    .quad 0
    .globl efi_system_table
efi_system_table:
    .quad 0


/* ---------- BSS: our own stack --------------------------------- *
 * 16 KiB matches arch/x86/boot/header.S's boot_stack — symmetry
 * helps future kernel-handoff debugging when both paths land in
 * start_kernel with a comparable stack profile.
 *
 * The PE/COFF .bss is loaded NOBITS-style: firmware zero-fills the
 * region when mapping the image. We don't need an explicit zeroing
 * pass like head_64.S does for the multiboot1 ELF. */
    .section .bss, "aw", @nobits
    .align 16
efi_stub_stack_bottom:
    .skip 16384
    .globl efi_stub_stack_top
efi_stub_stack_top:
