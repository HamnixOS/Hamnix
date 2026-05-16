/*
 * tests/u-binary/src/multi/multi.S — U6 multi-syscall Linux ELF fixture.
 *
 * Pure x86_64 asm, no libc. Linker hands us a raw _start with no setup.
 * Uses Linux x86_64 syscall numbers directly:
 *
 *   write        = 1
 *   brk          = 12
 *   getpid       = 39
 *   exit_group   = 231
 *   clock_gettime= 228
 *
 * What this binary tests:
 *
 *   1. write(1, "U6: start\n", ...) — sanity, matches U5.
 *   2. getpid() — must succeed (rax >= 1). On success we print
 *      "U6: pid ok\n".
 *   3. clock_gettime(CLOCK_MONOTONIC, &ts) where &ts is in our .bss.
 *      On rax == 0 we print "U6: clock ok\n". This stress-tests
 *      the kernel writing 16 bytes into a user buffer.
 *   4. brk(NULL) — returns current program break. If non-zero we
 *      print "U6: brk0 ok\n", save the value, and write one byte
 *      (0xAA) at that address. The user write proves the kmalloc-
 *      backed brk region is U=1 in the page tables (the kernel's
 *      4 GiB identity map sets US in the PDPT entries, so this
 *      should hold).
 *   5. brk(prev_brk + 0x1000) — grow the heap. On rax >= prev+0x1000
 *      print "U6: brk1 ok\n". Touch one byte in the new region too.
 *   6. write "U6: done\n", exit_group(0).
 *
 * Each line is a discrete success marker so the test harness can
 * pinpoint which syscall failed if the chain breaks anywhere along
 * the way.
 */

    .section .text
    .globl _start
_start:
    /* ---- 1. write(1, msg_start, len_start) ---- */
    movq    $1, %rax
    movq    $1, %rdi
    leaq    msg_start(%rip), %rsi
    movq    $len_start, %rdx
    syscall

    /* ---- 2. getpid() ---- */
    movq    $39, %rax
    syscall
    /* On Hamnix, slot indexes are >= 0; a valid pid is >= 1. Treat
     * anything <= 0 as failure. */
    testq   %rax, %rax
    jle     skip_pid
    movq    $1, %rax
    movq    $1, %rdi
    leaq    msg_pid(%rip), %rsi
    movq    $len_pid, %rdx
    syscall
skip_pid:

    /* ---- 3. clock_gettime(CLOCK_MONOTONIC=1, &ts_buf) ---- */
    movq    $228, %rax
    movq    $1, %rdi
    leaq    ts_buf(%rip), %rsi
    syscall
    /* rax == 0 on success, < 0 on error. */
    testq   %rax, %rax
    jne     skip_clock
    movq    $1, %rax
    movq    $1, %rdi
    leaq    msg_clock(%rip), %rsi
    movq    $len_clock, %rdx
    syscall
skip_clock:

    /* ---- 4. brk(NULL) ---- */
    movq    $12, %rax
    xorq    %rdi, %rdi
    syscall
    /* rax == 0 indicates OOM. Anything non-zero is the current
     * program break; save it in %r12 for the grow step. */
    testq   %rax, %rax
    jz      skip_brk0
    movq    %rax, %r12

    /* Touch one byte at *(brk_base). Faults here mean the kmalloc'd
     * region is not user-accessible; the kernel will trap and the
     * box will halt before we can print anything else. */
    movb    $0xAA, (%r12)

    movq    $1, %rax
    movq    $1, %rdi
    leaq    msg_brk0(%rip), %rsi
    movq    $len_brk0, %rdx
    syscall

    /* ---- 5. brk(prev + 0x1000) ---- */
    movq    $12, %rax
    leaq    0x1000(%r12), %rdi
    syscall
    /* On success rax >= prev + 0x1000. On Linux a grow failure
     * returns the OLD brk (which is %r12), so equality with %r12
     * means failure. */
    cmpq    %r12, %rax
    je      skip_brk1
    /* Touch one byte mid-region to prove the grow stuck. */
    movb    $0xBB, 0x800(%r12)
    movq    $1, %rax
    movq    $1, %rdi
    leaq    msg_brk1(%rip), %rsi
    movq    $len_brk1, %rdx
    syscall
skip_brk1:
skip_brk0:

    /* ---- 6. final marker + exit_group(0) ---- */
    movq    $1, %rax
    movq    $1, %rdi
    leaq    msg_done(%rip), %rsi
    movq    $len_done, %rdx
    syscall

    movq    $231, %rax
    xorq    %rdi, %rdi
    syscall

    /* Defensive halt in case exit_group returns (it shouldn't). */
1:  jmp     1b

.section .rodata
msg_start:  .ascii "U6: start\n"
len_start = . - msg_start
msg_pid:    .ascii "U6: pid ok\n"
len_pid   = . - msg_pid
msg_clock:  .ascii "U6: clock ok\n"
len_clock = . - msg_clock
msg_brk0:   .ascii "U6: brk0 ok\n"
len_brk0  = . - msg_brk0
msg_brk1:   .ascii "U6: brk1 ok\n"
len_brk1  = . - msg_brk1
msg_done:   .ascii "U6: done\n"
len_done  = . - msg_done

.section .bss
    .align 8
ts_buf:     .skip 16
