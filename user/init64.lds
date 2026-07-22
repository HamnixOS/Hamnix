/*
 * user/init64.lds - ELF64 linker script for NATIVE Hamnix user programs.
 *
 * The elf32-i386-wrapper format (user/init.lds) cannot hold the 64-bit
 * relocations (R_X86_64_64 / movabs / .quad-symbol) that clang emits for
 * REAL programs (the panel) — `as --32` fails with BFD_RELOC_64. This
 * script produces a genuine ELF64 EXEC instead: OSABI defaults to SYSV(0)
 * (NOT Linux), no PT_INTERP (-static -nostdlib), entry = _start, and the
 * Hamnix native syscall ABI (rax=num). The loader (fs/elf.ad) dispatches
 * on EI_CLASS==2 -> _load_elf64, and because OSABI==0 with no PT_INTERP
 * elf_is_linux_binary() returns 0 -> the task keeps NATIVE syscall
 * routing and the native argc/argv register handoff (see
 * arch/x86/kernel/syscall.ad do_execve: is_linux==0 path).
 *
 * ET_EXEC at a fixed low base (0x400000, same neighbourhood as Debian's
 * busybox-static which the ELF64 loader already ET_EXEC-maps): the loader
 * copies PT_LOAD into a memblock region and installs a per-task mapping
 * of [0x400000, hi) -> region. 0x400000 is well inside the first GiB the
 * elf_install_user_mapping single-1GiB-chunk installer supports, and it
 * dodges the NULL page.
 */

OUTPUT_FORMAT("elf64-x86-64")
OUTPUT_ARCH(i386:x86-64)
ENTRY(_start)

PHDRS {
    text PT_LOAD FLAGS(5);   /* R+X */
    data PT_LOAD FLAGS(6);   /* R+W */
}

SECTIONS
{
    /* Start the first PT_LOAD at a PAGE-ALIGNED base with the ELF + program
     * headers INCLUDED in the segment (p_offset=0, p_vaddr=0x400000) — the
     * exact layout Debian's busybox-static uses and the one the ELF64 loader
     * (_load_elf64 ET_EXEC arm + elf_install_user_range) is proven on. Do NOT
     * offset by SIZEOF_HEADERS: that would push .text to 0x4000b0 (a sub-page
     * lowest_v), and the loader's page-granular user mapping assumes a
     * page-aligned lowest_v == the copy anchor. */
    . = 0x400000;

    .text : ALIGN(16) {
        *(.text)
        *(.text.*)
    } : text

    .rodata : ALIGN(16) {
        *(.rodata)
        *(.rodata.*)
    } : text

    . = ALIGN(0x1000);

    .data : ALIGN(16) {
        *(.data)
        *(.data.*)
    } : data

    .bss : ALIGN(16) {
        *(.bss)
        *(.bss.*)
        *(COMMON)
    } : data

    /DISCARD/ : {
        *(.note.*)
        *(.comment)
        *(.eh_frame)
        *(.eh_frame_hdr)
        *(.eh_frame.*)
    }
}
