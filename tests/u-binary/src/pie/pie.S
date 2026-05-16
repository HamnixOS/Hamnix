/*
 * tests/u-binary/src/pie/pie.S — U10 static-PIE fixture.
 *
 * Pure x86_64 asm, no libc. Built as a Position-Independent Executable
 * so the linker emits .rela.dyn with R_X86_64_RELATIVE entries that
 * Hamnix's _load_elf64 must apply before the program runs.
 *
 * What this binary tests:
 *
 *   msg_table[0]   — a `.quad msg` in .data. The compiler can NOT
 *                    encode this as a RIP-relative reference (the
 *                    .quad slot has to hold the runtime *absolute*
 *                    address of `msg`), so the linker emits an
 *                    R_X86_64_RELATIVE relocation pointing at the
 *                    slot with addend = link-time vaddr of msg.
 *                    Without U10's fixup pass, the slot would still
 *                    hold the LINK-TIME address (something like
 *                    0x2000), which when used as a write(2) buffer
 *                    points into kernel-low memory and traps.
 *
 *   _start         — does `movq msg_table(%rip), %rsi` to read the
 *                    relocated pointer, then write(1, %rsi, msg_len)
 *                    + exit_group(0).
 *
 * Success marker: "U10: pie hello via reloc\n" appears on serial.
 * That string only reaches the console if (a) the R_X86_64_RELATIVE
 * entry was applied, AND (b) the rebased msg pointer survived the
 * write syscall. Either gap surfaces as the marker missing.
 */

    .section .text
    .globl _start
_start:
    /* msg_table is a 1-quad .data array. The quad's link-time value
     * is the address of `msg`; the loader rewrites it via
     * R_X86_64_RELATIVE before _start runs. We then deref it RIP-
     * relative to load the runtime address of `msg` into %rsi. */
    movq    msg_table(%rip), %rsi
    movq    $1, %rax                 /* SYS_write                  */
    movq    $1, %rdi                 /* fd = stdout                 */
    movq    $msg_len, %rdx
    syscall

    movq    $231, %rax               /* SYS_exit_group             */
    xorq    %rdi, %rdi
    syscall
    /* Defensive halt if exit_group ever returns. */
1:  jmp     1b

    .section .data
    .align 8
msg_table:
    .quad   msg                      /* needs R_X86_64_RELATIVE     */

    .section .rodata
msg:    .ascii "U10: pie hello via reloc\n"
msg_len = . - msg
