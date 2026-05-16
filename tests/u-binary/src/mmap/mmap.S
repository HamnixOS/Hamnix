/*
 * tests/u-binary/src/mmap/mmap.S — U7 writev + mmap/munmap fixture.
 *
 * Pure x86_64 asm, no libc. Built into a host-side Linux ELF with
 * OSABI=Linux so Hamnix's U2 detector flips is_linux_userspace=1.
 *
 * What this binary tests:
 *
 *   1. writev(1, iov[2], 2) — two iov entries forming "U7: writev ok\n".
 *      The kernel must walk the iovec array, call vfs_write for each
 *      chunk, accumulate the total, and return bytes-written. We
 *      assert rax > 0 and rely on the printed line for the test
 *      harness marker.
 *   2. mmap(NULL, 0x1000, PROT_READ|PROT_WRITE,
 *           MAP_ANONYMOUS|MAP_PRIVATE, -1, 0). The kernel must see
 *      all six args (a4 = -1 lives in %r8, a5 = 0 in %r9 — which
 *      means the SYSCALL stub must forward those regs into
 *      linux_u_syscall_dispatch). We assert rax > 0, then write a
 *      byte and read it back to prove the returned page is actually
 *      user-accessible and writable.
 *   3. munmap(base, 0x1000). Must return 0. If the kernel returns
 *      -EINVAL the previous mmap allocation will leak — diagnosed
 *      via the marker line missing in the test harness.
 *
 * Plain write() prints the success markers so the test harness can
 * grep for "U7: writev ok" and "U7: mmap ok" independently of the
 * sysv calls themselves.
 */

    .section .text
    .globl _start
_start:
    /* ---- 1. writev(1, iov, 2) -------------------------------------- *
     * Hamnix's ELF loader does not relocate absolute pointers (no .rel
     * / .rela handling at this milestone — see fs/elf.ad), so we can't
     * keep the iovec base/len pairs in .rodata as `.quad iov0_base` —
     * those addresses are link-time virtual and point off into nowhere
     * once the loader rebases the segment.
     *
     * Build the iovec on the stack at runtime instead: `leaq` is
     * RIP-relative (it works because the address arithmetic happens
     * after the loader has placed the code) and the resulting absolute
     * pointers live in stack memory which the kernel reads via the same
     * identity-mapped path it uses for any other user buffer.
     *
     * Stack layout (32 bytes, two iovec entries):
     *   0(%rsp): iov0_base
     *   8(%rsp): iov0_len
     *  16(%rsp): iov1_base
     *  24(%rsp): iov1_len
     */
    subq    $32, %rsp                  /* room for two iovec entries  */
    leaq    iov0_base(%rip), %rax
    movq    %rax, 0(%rsp)
    movq    $iov0_len, 8(%rsp)
    leaq    iov1_base(%rip), %rax
    movq    %rax, 16(%rsp)
    movq    $iov1_len, 24(%rsp)

    movq    $20, %rax                  /* SYS_writev                  */
    movq    $1,  %rdi                  /* fd = stdout                 */
    movq    %rsp, %rsi                 /* iovec array base = %rsp     */
    movq    $2,  %rdx                  /* iovcnt                      */
    syscall
    addq    $32, %rsp                  /* drop the iovec scratch      */
    testq   %rax, %rax
    jle     fail_writev

    /* ---- 2. mmap(NULL, 0x1000, 3, 0x22, -1, 0) --------------------- *
     * args: a0=addr, a1=length, a2=prot, a3=flags, a4=fd, a5=offset
     *   prot = PROT_READ|PROT_WRITE   = 3
     *   flags = MAP_PRIVATE|MAP_ANON  = 0x22
     *   fd    = -1
     */
    movq    $9, %rax                   /* SYS_mmap                    */
    xorq    %rdi, %rdi                 /* a0 = NULL                   */
    movq    $0x1000, %rsi              /* a1 = length                 */
    movq    $3, %rdx                   /* a2 = prot                   */
    movq    $0x22, %r10                /* a3 = flags                  */
    movq    $-1, %r8                   /* a4 = fd = -1                */
    xorq    %r9, %r9                   /* a5 = offset = 0             */
    syscall
    /* On success rax = base address (non-zero). On failure rax is a
     * small negative errno or 0. Treat both <= 0 and the "errno page"
     * (-4095..-1) as a failure. */
    cmpq    $0, %rax
    jle     fail_mmap
    movq    %rax, %r12                 /* save base in callee-saved   */

    /* Prove the page is writable: store 0x55 at base, then load and
     * compare. If the load doesn't equal 0x55 the kernel didn't
     * actually give us a writable page. */
    movb    $0x55, (%r12)
    movzbq  (%r12), %rax
    cmpq    $0x55, %rax
    jne     fail_mmap

    /* ---- 3. munmap(base, 0x1000) ----------------------------------- */
    movq    $11, %rax                  /* SYS_munmap                  */
    movq    %r12, %rdi                 /* a0 = addr                   */
    movq    $0x1000, %rsi              /* a1 = length                 */
    syscall
    testq   %rax, %rax
    jnz     fail_munmap

    /* ---- 4. Success marker via plain write ------------------------- */
    movq    $1, %rax                   /* SYS_write                   */
    movq    $1, %rdi                   /* fd = stdout                 */
    leaq    msg_mmap_ok(%rip), %rsi
    movq    $len_mmap_ok, %rdx
    syscall

    /* ---- 5. exit_group(0) ------------------------------------------ */
    movq    $231, %rax                 /* SYS_exit_group              */
    xorq    %rdi, %rdi
    syscall
    /* Defensive halt if exit_group ever returns. */
1:  jmp     1b

fail_writev:
    movq    $1, %rax
    movq    $2, %rdi                   /* stderr                      */
    leaq    msg_fail_writev(%rip), %rsi
    movq    $len_fail_writev, %rdx
    syscall
    movq    $231, %rax
    movq    $1, %rdi
    syscall
2:  jmp     2b

fail_mmap:
    movq    $1, %rax
    movq    $2, %rdi
    leaq    msg_fail_mmap(%rip), %rsi
    movq    $len_fail_mmap, %rdx
    syscall
    movq    $231, %rax
    movq    $2, %rdi
    syscall
3:  jmp     3b

fail_munmap:
    movq    $1, %rax
    movq    $2, %rdi
    leaq    msg_fail_munmap(%rip), %rsi
    movq    $len_fail_munmap, %rdx
    syscall
    movq    $231, %rax
    movq    $3, %rdi
    syscall
4:  jmp     4b

    .section .rodata
    .align 8
iov0_base:  .ascii "U7: writev "
iov0_end:
    .equ    iov0_len, iov0_end - iov0_base

iov1_base:  .ascii "ok\n"
iov1_end:
    .equ    iov1_len, iov1_end - iov1_base

msg_mmap_ok:      .ascii "U7: mmap ok\n"
len_mmap_ok = . - msg_mmap_ok

msg_fail_writev:  .ascii "U7: writev FAIL\n"
len_fail_writev = . - msg_fail_writev

msg_fail_mmap:    .ascii "U7: mmap FAIL\n"
len_fail_mmap = . - msg_fail_mmap

msg_fail_munmap:  .ascii "U7: munmap FAIL\n"
len_fail_munmap = . - msg_fail_munmap
