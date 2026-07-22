/* scripts/adder_llvm_runtime_native.s — NATIVE Hamnix runtime supplement for
 * the Adder LLVM backend (adder/compiler/ssa_llvm.ad, --backend=llvm), used by
 * scripts/adder_cc_llvm_native.sh.
 *
 * The glibc lane (scripts/adder_llvm_runtime.c) supplies print_u64 with a libc
 * `write(2)`. The NATIVE lane is freestanding: _start and the sys_* syscall
 * wrappers already come from user/runtime.S, so all this file adds is the one
 * prelude helper that the SSA integer subset bails on and emits as an external
 * `declare i64 @print_u64(i64)`:
 *
 *   print_u64(v) — decimal uint64 + newline to fd 1 via the Hamnix SYS_WRITE
 *                  (rax=8) syscall, byte-for-byte identical to
 *                  tests/bench/opt/_prelude.ad's print_u64. Returns 0 so the
 *                  .ll ABI `declare i64 @print_u64(i64)` matches.
 *
 * 64-bit code in an elf32-i386 wrapper (the `.code64` trick, same as
 * user/runtime.S) — the wrapper prepends `.code64` before assembling with
 * `as --32`. Syscall arg regs: rax=num, rdi/rsi/rdx (Hamnix ABI, <=3 args here
 * align with SysV). */

    .code64
    .section .text, "ax"

    .globl print_u64
    .type print_u64, @function
print_u64:
    /* %rdi = v (uint64). Build the decimal string backwards into a
     * 32-byte stack buffer with the trailing newline at the high end,
     * then one SYS_WRITE of (fd=1, buf=first-digit, len). */
    movq    %rdi, %rax              /* rax = running quotient (the value) */
    subq    $40, %rsp               /* 32-byte buffer + 8 slack (16-align) */
    leaq    32(%rsp), %rcx          /* rcx = one-past-buffer-end */
    movq    %rcx, %rsi              /* rsi = write cursor */
    decq    %rsi
    movb    $10, (%rsi)             /* trailing '\n' at the last byte */
    movq    $10, %r8                /* divisor */
    testq   %rax, %rax
    jnz     .Lpu_loop
    /* v == 0 -> a single '0' digit */
    decq    %rsi
    movb    $48, (%rsi)
    jmp     .Lpu_write
.Lpu_loop:
    testq   %rax, %rax
    jz      .Lpu_write
    xorq    %rdx, %rdx
    divq    %r8                     /* rax = v/10, rdx = v%10 */
    addb    $48, %dl                /* rem -> ASCII digit */
    decq    %rsi
    movb    %dl, (%rsi)
    jmp     .Lpu_loop
.Lpu_write:
    /* SYS_WRITE(fd=1, buf=rsi, len = rcx - rsi) */
    movq    %rcx, %rdx
    subq    %rsi, %rdx              /* rdx = byte count (digits + newline) */
    movq    $1, %rdi                /* fd 1 = stdout */
    movq    $8, %rax                /* SYS_WRITE */
    syscall
    addq    $40, %rsp
    xorq    %rax, %rax              /* return 0 (i64) */
    ret
    .size print_u64, .-print_u64
