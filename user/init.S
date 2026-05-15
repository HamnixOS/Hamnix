/*
 * user/init.S - first real userspace binary, loaded from cpio at boot.
 *
 * Hand-written so we don't need a Hamnix→user-mode compiler target
 * yet. The whole thing is position-independent (all data access via
 * RIP-relative leaq) so the kernel can place the loaded segment at
 * any physical address and just jump in.
 *
 * Run via SYSCALL ABI:
 *   %rax = nr   (0=PUTC, 1=EXIT, 8=WRITE, 9=LSEEK, 5=OPEN, 6=READ, 7=CLOSE)
 *   %rdi/%rsi/%rdx/%r10/%r8/%r9 = args
 *   return in %rax
 *
 * What this /init does:
 *   1. SYS_WRITE(fd=1, "Hello from /init - loaded from cpio via ELF!\n")
 *   2. SYS_OPEN("/version"), read, write to stdout, close
 *   3. SYS_EXIT(0)
 *
 * Proves the whole pipeline: ELF parsing → segment copy → enter_user_mode
 * → user-mode SYSCALL → VFS over cpio.
 */

    .code64
    .section .text, "ax"

    .globl _start
_start:
    /* write(1, banner, banner_len) */
    movq    $1, %rdi
    leaq    init_banner(%rip), %rsi
    movq    $init_banner_end - init_banner, %rdx
    movq    $8, %rax                /* SYS_WRITE */
    syscall

    /* fd = open("/version") */
    leaq    init_fname_version(%rip), %rdi
    movq    $5, %rax                /* SYS_OPEN */
    syscall
    movq    %rax, %r13              /* save fd */

    /* loop: while ((n = read(fd, buf, 64)) > 0) write(1, buf, n) */
.Linit_rl:
    movq    %r13, %rdi
    leaq    init_buf(%rip), %rsi
    movq    $64, %rdx
    movq    $6, %rax                /* SYS_READ */
    syscall
    testq   %rax, %rax
    jle     .Linit_done

    movq    %rax, %rdx              /* n */
    movq    $1, %rdi
    leaq    init_buf(%rip), %rsi
    movq    $8, %rax                /* SYS_WRITE */
    syscall
    jmp     .Linit_rl

.Linit_done:
    /* close(fd) */
    movq    %r13, %rdi
    movq    $7, %rax                /* SYS_CLOSE */
    syscall

    /* write(1, "ok\n", 3) */
    movq    $1, %rdi
    leaq    init_ok(%rip), %rsi
    movq    $init_ok_end - init_ok, %rdx
    movq    $8, %rax
    syscall

    /* execve("/hello", NULL) — replaces this task's user image with
     * the /hello binary. As of M16.35 SYS_EXECVE takes a1 = argv;
     * we pass NULL because /hello takes no args. SYS_EXECVE never
     * returns on success, so the SYS_EXIT below only runs if the
     * exec fails. */
    leaq    init_path_hello(%rip), %rdi
    xorq    %rsi, %rsi              /* argv = NULL */
    movq    $10, %rax               /* SYS_EXECVE */
    syscall

    /* exec failed (or fell through) — exit cleanly. */
    movq    $1, %rax                /* SYS_EXIT */
    syscall

.Linit_hang:
    jmp     .Linit_hang

    /* String / buffer area — kept in the same .text segment so a
     * single PT_LOAD covers code + data. The ELF loader allocates
     * one chunk and memcpys the whole filesz over. */
    .balign 8
init_banner:
    .ascii "[/init] Hello from a real userland ELF, "
    .ascii "loaded from cpio.\n"
init_banner_end:

init_fname_version:
    .asciz "/version"

init_path_hello:
    .asciz "/hello"

init_ok:
    .ascii "[/init] ok, exec'ing /hello\n"
init_ok_end:

    .balign 8
init_buf:
    .skip 64
