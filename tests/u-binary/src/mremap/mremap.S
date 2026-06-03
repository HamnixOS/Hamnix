/*
 * tests/u-binary/src/mremap/mremap.S — mremap(2) fixture.
 *
 * Pure x86_64 asm, no libc. Built into a host-side Linux ELF with
 * OSABI=Linux so Hamnix's U2 detector flips is_linux_userspace=1.
 *
 * Exercises the real mremap() implementation (linux_abi/u_syscalls.ad
 * -> mm/vma.ad::vma_mremap):
 *
 *   (a) GROW + MOVE:
 *       mmap a 6 MiB anon region (lands in the windowed [1G,4G) VMA
 *       region). Write a sentinel 0xA5 at byte 0 and at byte old_len-1.
 *       mremap(old, 6MiB, 10MiB, MREMAP_MAYMOVE). Verify rax > 0, then
 *       check the head sentinel survived the (possible) move AND the
 *       new tail (byte new_len-1) is writable+readable.
 *       Prints "MREMAP: grow ok".
 *
 *   (b) SHRINK:
 *       mremap(region, 10MiB, 2MiB, 0). Verify rax == base (shrink in
 *       place) and the head sentinel still reads 0xA5.
 *       Prints "MREMAP: shrink ok".
 *
 *   (c) GROW WITHOUT MAYMOVE that can't extend in place:
 *       mmap a single 4 KiB page (identity-mapped, NOT windowed -> the
 *       kernel never attempts grow-in-place there). mremap to 8 KiB
 *       with flags=0 (no MAYMOVE). Linux semantics: must return
 *       -ENOMEM (-12), NOT silently move. Verify rax == -12.
 *       Prints "MREMAP: nomove ok".
 *
 * On any failure the corresponding "... FAIL" line is printed and the
 * binary exits non-zero so the harness flags it.
 *
 * Syscall numbers (x86_64): mmap=9, munmap=11, mremap=25, write=1,
 * exit_group=231.
 */

    .equ SYS_mmap,       9
    .equ SYS_munmap,     11
    .equ SYS_mremap,     25
    .equ SYS_write,      1
    .equ SYS_exit_group, 231

    .equ PROT_RW,        3        /* PROT_READ|PROT_WRITE          */
    .equ MAP_ANON_PRIV,  0x22     /* MAP_PRIVATE|MAP_ANONYMOUS     */
    .equ MREMAP_MAYMOVE, 1

    .equ OLD_LEN,  0x600000       /* 6 MiB  (windowed)             */
    .equ GROW_LEN, 0xA00000       /* 10 MiB                        */
    .equ SHRINK_LEN, 0x200000     /* 2 MiB                         */
    .equ SENT,     0xA5

    .section .text
    .globl _start
_start:
    /* ---- (a) mmap OLD_LEN anonymous ------------------------------- */
    movq    $SYS_mmap, %rax
    xorq    %rdi, %rdi                 /* addr = NULL               */
    movq    $OLD_LEN, %rsi             /* length                    */
    movq    $PROT_RW, %rdx
    movq    $MAP_ANON_PRIV, %r10
    movq    $-1, %r8                   /* fd = -1                   */
    xorq    %r9, %r9                   /* offset = 0                */
    syscall
    cmpq    $0, %rax
    jle     fail_grow
    movq    %rax, %r12                 /* r12 = old base            */

    /* write head sentinel at byte 0, tail sentinel at byte OLD_LEN-1 */
    movb    $SENT, (%r12)
    leaq    OLD_LEN-1(%r12), %rbx
    movb    $SENT, (%rbx)

    /* ---- (a) mremap OLD_LEN -> GROW_LEN, MAYMOVE ------------------ */
    movq    $SYS_mremap, %rax
    movq    %r12, %rdi                 /* old_addr                  */
    movq    $OLD_LEN, %rsi             /* old_len                   */
    movq    $GROW_LEN, %rdx            /* new_len                   */
    movq    $MREMAP_MAYMOVE, %r10      /* flags                     */
    xorq    %r8, %r8                   /* new_addr (unused)         */
    syscall
    cmpq    $0, %rax
    jle     fail_grow
    movq    %rax, %r13                 /* r13 = new base            */

    /* head sentinel must have survived the move */
    movzbq  (%r13), %rax
    cmpq    $SENT, %rax
    jne     fail_grow

    /* old tail sentinel (byte OLD_LEN-1) must have survived too */
    leaq    OLD_LEN-1(%r13), %rbx
    movzbq  (%rbx), %rax
    cmpq    $SENT, %rax
    jne     fail_grow

    /* new tail (byte GROW_LEN-1) must be writable + readable */
    leaq    GROW_LEN-1(%r13), %rbx
    movb    $0x5A, (%rbx)
    movzbq  (%rbx), %rax
    cmpq    $0x5A, %rax
    jne     fail_grow

    /* print "MREMAP: grow ok\n" */
    movq    $SYS_write, %rax
    movq    $1, %rdi
    leaq    msg_grow_ok(%rip), %rsi
    movq    $len_grow_ok, %rdx
    syscall

    /* ---- (b) mremap GROW_LEN -> SHRINK_LEN (shrink in place) ------ */
    movq    $SYS_mremap, %rax
    movq    %r13, %rdi                 /* old_addr (current base)   */
    movq    $GROW_LEN, %rsi            /* old_len                   */
    movq    $SHRINK_LEN, %rdx          /* new_len                   */
    xorq    %r10, %r10                 /* flags = 0                 */
    xorq    %r8, %r8
    syscall
    /* shrink stays in place -> rax must equal the old base r13 */
    cmpq    %r13, %rax
    jne     fail_shrink

    /* head sentinel must still read 0xA5 */
    movzbq  (%r13), %rax
    cmpq    $SENT, %rax
    jne     fail_shrink

    movq    $SYS_write, %rax
    movq    $1, %rdi
    leaq    msg_shrink_ok(%rip), %rsi
    movq    $len_shrink_ok, %rdx
    syscall

    /* clean up the shrunk region */
    movq    $SYS_munmap, %rax
    movq    %r13, %rdi
    movq    $SHRINK_LEN, %rsi
    syscall

    /* ---- (c) grow WITHOUT MAYMOVE that can't extend -> -ENOMEM ---- */
    movq    $SYS_mmap, %rax
    xorq    %rdi, %rdi
    movq    $0x1000, %rsi              /* one page (identity-mapped) */
    movq    $PROT_RW, %rdx
    movq    $MAP_ANON_PRIV, %r10
    movq    $-1, %r8
    xorq    %r9, %r9
    syscall
    cmpq    $0, %rax
    jle     fail_nomove
    movq    %rax, %r14                 /* r14 = small base          */

    movq    $SYS_mremap, %rax
    movq    %r14, %rdi
    movq    $0x1000, %rsi              /* old_len  = 4 KiB          */
    movq    $0x2000, %rdx              /* new_len  = 8 KiB          */
    xorq    %r10, %r10                 /* flags = 0 (no MAYMOVE)    */
    xorq    %r8, %r8
    syscall
    /* must be exactly -ENOMEM (-12) */
    cmpq    $-12, %rax
    jne     fail_nomove

    movq    $SYS_write, %rax
    movq    $1, %rdi
    leaq    msg_nomove_ok(%rip), %rsi
    movq    $len_nomove_ok, %rdx
    syscall

    /* ---- success: exit_group(0) ---------------------------------- */
    movq    $SYS_exit_group, %rax
    xorq    %rdi, %rdi
    syscall
1:  jmp     1b

fail_grow:
    movq    $SYS_write, %rax
    movq    $2, %rdi
    leaq    msg_grow_fail(%rip), %rsi
    movq    $len_grow_fail, %rdx
    syscall
    movq    $SYS_exit_group, %rax
    movq    $1, %rdi
    syscall
2:  jmp     2b

fail_shrink:
    movq    $SYS_write, %rax
    movq    $2, %rdi
    leaq    msg_shrink_fail(%rip), %rsi
    movq    $len_shrink_fail, %rdx
    syscall
    movq    $SYS_exit_group, %rax
    movq    $2, %rdi
    syscall
3:  jmp     3b

fail_nomove:
    movq    $SYS_write, %rax
    movq    $2, %rdi
    leaq    msg_nomove_fail(%rip), %rsi
    movq    $len_nomove_fail, %rdx
    syscall
    movq    $SYS_exit_group, %rax
    movq    $3, %rdi
    syscall
4:  jmp     4b

    .section .rodata
    .align 8
msg_grow_ok:     .ascii "MREMAP: grow ok\n"
len_grow_ok = . - msg_grow_ok
msg_shrink_ok:   .ascii "MREMAP: shrink ok\n"
len_shrink_ok = . - msg_shrink_ok
msg_nomove_ok:   .ascii "MREMAP: nomove ok\n"
len_nomove_ok = . - msg_nomove_ok

msg_grow_fail:   .ascii "MREMAP: grow FAIL\n"
len_grow_fail = . - msg_grow_fail
msg_shrink_fail: .ascii "MREMAP: shrink FAIL\n"
len_shrink_fail = . - msg_shrink_fail
msg_nomove_fail: .ascii "MREMAP: nomove FAIL\n"
len_nomove_fail = . - msg_nomove_fail
