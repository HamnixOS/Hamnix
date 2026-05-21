/*
 * tests/u-binary/src/vm_maturity/vm_maturity.S — §1 maturity of
 * mprotect / madvise(MADV_DONTNEED) / MAP_FIXED.
 *
 * Pure x86_64 asm, no libc. Built into a host-side Linux ELF with
 * OSABI=Linux so Hamnix's U2 detector flips is_linux_userspace=1.
 *
 * Item 4 of the §1 kernel-roadmap task asks for these three syscalls
 * to work for arbitrary callers, not just the dynamic loader's narrow
 * patterns. This fixture exercises them with OBSERVABLE, non-faulting
 * checks (a genuine protection fault would halt the kernel, so the
 * test cannot prove "a write to a PROT_READ page faults" directly —
 * it proves the calls SUCCEED and have their visible side effects):
 *
 *   T1 mprotect over a sub-range:
 *     mmap a 4-page RW anon region, mprotect the middle 2 pages to
 *     PROT_READ then back to PROT_READ|PROT_WRITE. Both calls must
 *     return 0. Then write the whole region and read it back — after
 *     restoring PROT_WRITE the region is fully writable again, so the
 *     readback must match. This drives vma_protect's PTE re-walk and
 *     the VMA split (the middle range becomes its own VMA, then the
 *     prot is restored).
 *
 *   T2 madvise(MADV_DONTNEED) drops pages:
 *     Write a sentinel into a page, madvise(MADV_DONTNEED) it, read
 *     back — the page must now be ZERO (DONTNEED on anonymous memory
 *     resets it). madvise must return 0.
 *
 *   T3 MAP_FIXED replaces an existing mapping:
 *     mmap a 2-page anon region, write a sentinel, then mmap again
 *     with MAP_FIXED at the SAME address. The fixed mapping must land
 *     at exactly that address and read back as ZERO (fresh pages),
 *     proving MAP_FIXED replaced the prior mapping rather than being
 *     treated as a hint.
 *
 * Markers (the harness greps the serial log):
 *   "VM: start"
 *   "VM: T1 ok" / "VM: T2 ok" / "VM: T3 ok"
 *   "VM: PASS"
 *   "VM: FAIL ..."  on any failure.
 */

    .set PAGE,           0x1000

    .set SYS_write,      1
    .set SYS_mmap,       9
    .set SYS_mprotect,   10
    .set SYS_munmap,     11
    .set SYS_madvise,    28
    .set SYS_exit_group, 231

    .set PROT_READ,      0x1
    .set PROT_WRITE,     0x2
    .set MAP_PRIVATE,    0x02
    .set MAP_FIXED,      0x10
    .set MAP_ANON,       0x20
    .set MADV_DONTNEED,  4

    .section .text
    .globl _start
_start:
    movq    $SYS_write, %rax
    movq    $1, %rdi
    leaq    msg_start(%rip), %rsi
    movq    $len_start, %rdx
    syscall

    /* ============ T1 — mprotect over a sub-range ================== */
    /* mmap 4 pages RW anon. */
    movq    $SYS_mmap, %rax
    xorq    %rdi, %rdi
    movq    $0x4000, %rsi              /* 4 pages                     */
    movq    $3, %rdx                   /* PROT_READ|PROT_WRITE        */
    movq    $0x22, %r10                /* MAP_PRIVATE|MAP_ANON        */
    movq    $-1, %r8
    xorq    %r9, %r9
    syscall
    cmpq    $0, %rax
    jle     fail_t1
    movq    %rax, %r14                 /* %r14 = region base          */

    /* mprotect middle 2 pages -> PROT_READ. */
    movq    $SYS_mprotect, %rax
    leaq    PAGE(%r14), %rdi           /* base + 1 page               */
    movq    $0x2000, %rsi              /* 2 pages                     */
    movq    $PROT_READ, %rdx
    syscall
    testq   %rax, %rax
    jnz     fail_t1

    /* mprotect the same middle range back to RW. */
    movq    $SYS_mprotect, %rax
    leaq    PAGE(%r14), %rdi
    movq    $0x2000, %rsi
    movq    $3, %rdx                   /* PROT_READ|PROT_WRITE        */
    syscall
    testq   %rax, %rax
    jnz     fail_t1

    /* Whole region is RW again — write a sentinel into all 4 pages
     * and read each back. */
    movq    $0x1234000, %rcx
    movq    %rcx, 0(%r14)
    movq    %rcx, PAGE(%r14)
    movq    %rcx, 2*PAGE(%r14)
    movq    %rcx, 3*PAGE(%r14)
    movq    0(%r14), %rax
    cmpq    %rcx, %rax
    jne     fail_t1
    movq    PAGE(%r14), %rax
    cmpq    %rcx, %rax
    jne     fail_t1
    movq    2*PAGE(%r14), %rax
    cmpq    %rcx, %rax
    jne     fail_t1
    movq    3*PAGE(%r14), %rax
    cmpq    %rcx, %rax
    jne     fail_t1

    movq    $SYS_write, %rax
    movq    $1, %rdi
    leaq    msg_t1(%rip), %rsi
    movq    $len_t1, %rdx
    syscall

    /* ============ T2 — madvise(MADV_DONTNEED) drops pages ========= */
    /* Reuse page 0 of the region: write a sentinel, DONTNEED it,
     * read back -> must be zero. */
    movq    $0x55556666, %rcx
    movq    %rcx, 0(%r14)
    movq    %rcx, 8(%r14)              /* a second word, same page    */

    movq    $SYS_madvise, %rax
    movq    %r14, %rdi
    movq    $PAGE, %rsi                /* 1 page                      */
    movq    $MADV_DONTNEED, %rdx
    syscall
    testq   %rax, %rax
    jnz     fail_t2

    movq    0(%r14), %rax
    testq   %rax, %rax
    jnz     fail_t2                    /* not zeroed -> DONTNEED no-op */
    movq    8(%r14), %rax
    testq   %rax, %rax
    jnz     fail_t2

    movq    $SYS_write, %rax
    movq    $1, %rdi
    leaq    msg_t2(%rip), %rsi
    movq    $len_t2, %rdx
    syscall

    /* ============ T3 — MAP_FIXED replaces a mapping =============== */
    /* mmap a 2-page anon region. */
    movq    $SYS_mmap, %rax
    xorq    %rdi, %rdi
    movq    $0x2000, %rsi
    movq    $3, %rdx
    movq    $0x22, %r10
    movq    $-1, %r8
    xorq    %r9, %r9
    syscall
    cmpq    $0, %rax
    jle     fail_t3
    movq    %rax, %r13                 /* %r13 = region base          */

    /* Write a sentinel so a stale mapping would be detectable. */
    movq    $0x7777AAAA, %rcx
    movq    %rcx, 0(%r13)
    movq    %rcx, PAGE(%r13)

    /* mmap again, MAP_FIXED, at the SAME address. Must return exactly
     * that address. */
    movq    $SYS_mmap, %rax
    movq    %r13, %rdi                 /* a0 = fixed addr             */
    movq    $0x2000, %rsi
    movq    $3, %rdx
    movq    $0x32, %r10                /* MAP_PRIVATE|FIXED|ANON      */
    movq    $-1, %r8
    xorq    %r9, %r9
    syscall
    cmpq    %r13, %rax
    jne     fail_t3                    /* MAP_FIXED ignored the addr  */

    /* The fixed mapping is fresh pages — must read back as zero, NOT
     * the 0x7777AAAA sentinel from the replaced mapping. */
    movq    0(%r13), %rax
    testq   %rax, %rax
    jnz     fail_t3
    movq    PAGE(%r13), %rax
    testq   %rax, %rax
    jnz     fail_t3

    /* The fixed mapping must be usable: write + read back. */
    movq    $0x0BADF00D, %rcx
    movq    %rcx, 0(%r13)
    movq    0(%r13), %rax
    cmpq    %rcx, %rax
    jne     fail_t3

    movq    $SYS_write, %rax
    movq    $1, %rdi
    leaq    msg_t3(%rip), %rsi
    movq    $len_t3, %rdx
    syscall

    /* ============ all clean ====================================== */
    movq    $SYS_write, %rax
    movq    $1, %rdi
    leaq    msg_pass(%rip), %rsi
    movq    $len_pass, %rdx
    syscall
    movq    $SYS_exit_group, %rax
    xorq    %rdi, %rdi
    syscall
1:  jmp     1b

fail_t1:
    leaq    msg_fail_t1(%rip), %rsi
    movq    $len_fail_t1, %rdx
    jmp     fail_emit
fail_t2:
    leaq    msg_fail_t2(%rip), %rsi
    movq    $len_fail_t2, %rdx
    jmp     fail_emit
fail_t3:
    leaq    msg_fail_t3(%rip), %rsi
    movq    $len_fail_t3, %rdx
    jmp     fail_emit
fail_emit:
    movq    $SYS_write, %rax
    movq    $2, %rdi
    syscall
    movq    $SYS_exit_group, %rax
    movq    $1, %rdi
    syscall
2:  jmp     2b

    .section .rodata
    .align 8
msg_start:    .ascii "VM: start\n"
len_start = . - msg_start
msg_t1:       .ascii "VM: T1 ok\n"
len_t1 = . - msg_t1
msg_t2:       .ascii "VM: T2 ok\n"
len_t2 = . - msg_t2
msg_t3:       .ascii "VM: T3 ok\n"
len_t3 = . - msg_t3
msg_pass:     .ascii "VM: PASS\n"
len_pass = . - msg_pass
msg_fail_t1:  .ascii "VM: FAIL T1 mprotect sub-range\n"
len_fail_t1 = . - msg_fail_t1
msg_fail_t2:  .ascii "VM: FAIL T2 madvise DONTNEED did not drop pages\n"
len_fail_t2 = . - msg_fail_t2
msg_fail_t3:  .ascii "VM: FAIL T3 MAP_FIXED did not replace mapping\n"
len_fail_t3 = . - msg_fail_t3

    .section .note.GNU-stack,"",@progbits
