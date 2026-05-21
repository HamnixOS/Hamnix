/*
 * tests/u-binary/src/mmap_shared/mmap_shared.S — §1 cross-process
 * MAP_SHARED coherence.
 *
 * Pure x86_64 asm, no libc. Built into a host-side Linux ELF with
 * OSABI=Linux so Hamnix's U2 detector flips is_linux_userspace=1.
 *
 * This is the INVERSE of tests/u-binary/src/mmap_fork: that fixture
 * proves a MAP_PRIVATE region COW-splits on write (the child's writes
 * never reach the parent). This fixture proves a MAP_SHARED anonymous
 * region is GENUINELY SHARED — a write by one process is visible to
 * another process mapping the same object (/dev/shm-style coherence).
 *
 * IMPORTANT — register state across fork. Hamnix's fork builds the
 * child's initial register frame fresh, so the child resumes with its
 * general-purpose registers NOT carried over from the parent. This
 * fixture therefore keeps EVERY value it needs across the fork
 * boundary in process memory, never in a register:
 *   - the mmap region base + the iteration index live in .bss globals
 *     (g_base / g_iter), which are part of the COW-shared ELF image,
 *   - the handshake / sentinel values are passed through the SHARED
 *     mmap region itself (the thing under test).
 * Each fork child re-loads g_base / g_iter from memory.
 *
 * Each of MS_ITERS iterations:
 *   1. mmap(NULL, 2 pages, RW, MAP_SHARED|MAP_ANONYMOUS, -1, 0).
 *   2. Stash the base in g_base; write a PARENT handshake into page 0.
 *   3. fork().
 *   4. CHILD: re-load g_base, verify page 0 holds the parent's
 *      handshake (proof it sees the parent's pre-fork write through
 *      the shared frame), then write a CHILD sentinel into BOTH pages
 *      and exit_group(0).
 *   5. PARENT: wait4() the child, then read page 0 AND page 1 back.
 *      They MUST hold the CHILD's sentinel — proof the child's writes
 *      landed in the SHARED frames the parent still maps. If the
 *      parent still sees its own handshake the region was silently
 *      MAP_PRIVATE — the bug §1 fixes.
 *   6. munmap() the region; must return 0.
 *
 * Markers (the harness greps the serial log):
 *   "MS: start"
 *   "MS: iter ok"   once per iteration
 *   "MS: PASS"      all iterations clean
 *   "MS: FAIL ..."  a coherence violation / mmap / fork / munmap error
 */

    .set MS_ITERS,      6
    .set PAGE,          0x1000
    .set REGION_LEN,    0x2000        /* two pages */

    .set SYS_write,     1
    .set SYS_mmap,      9
    .set SYS_munmap,    11
    .set SYS_fork,      57
    .set SYS_wait4,     61
    .set SYS_exit_group, 231

    /* MAP_SHARED|MAP_ANONYMOUS = 0x01 | 0x20 = 0x21 */
    .set MAP_FLAGS,     0x21

    /* Handshake / sentinel family tags (high 16 bits). */
    .set HS_PARENT,     0x4444        /* parent handshake 0x4444iiii  */
    .set HS_CHILD,      0x9999        /* child sentinel   0x9999iiii  */

    .section .text
    .globl _start
_start:
    /* ---- "MS: start" --------------------------------------------- */
    movq    $SYS_write, %rax
    movq    $1, %rdi
    leaq    msg_start(%rip), %rsi
    movq    $len_start, %rdx
    syscall

    /* g_iter = 0 */
    movq    $0, g_iter(%rip)

iter_loop:
    movq    g_iter(%rip), %r15
    cmpq    $MS_ITERS, %r15
    jge     all_done

    /* ---- 1. mmap a 2-page anonymous SHARED region ---------------- */
    movq    $SYS_mmap, %rax
    xorq    %rdi, %rdi                 /* a0 = NULL                   */
    movq    $REGION_LEN, %rsi          /* a1 = length = 2 pages       */
    movq    $3, %rdx                   /* a2 = PROT_READ|PROT_WRITE   */
    movq    $MAP_FLAGS, %r10           /* a3 = MAP_SHARED|MAP_ANON    */
    movq    $-1, %r8                   /* a4 = fd = -1                */
    xorq    %r9, %r9                   /* a5 = offset = 0             */
    syscall
    cmpq    $0, %rax
    jle     fail_mmap

    /* ---- 2. stash base in g_base; write the PARENT handshake ----- *
     * handshake = (0x4444 << 16) | iter. */
    movq    %rax, g_base(%rip)
    movq    g_iter(%rip), %rbx
    movq    $HS_PARENT, %rcx
    shlq    $16, %rcx
    orq     %rbx, %rcx                 /* %rcx = parent handshake     */
    movq    g_base(%rip), %rdx
    movq    %rcx, 0(%rdx)              /* page 0 <- handshake         */

    /* ---- 3. fork() ----------------------------------------------- */
    movq    $SYS_fork, %rax
    syscall
    cmpq    $0, %rax
    jl      fail_fork
    testq   %rax, %rax
    jz      child_path                 /* rax == 0 -> child           */

    /* ---- parent: wait4(child, &status, 0, 0) --------------------- */
    movq    %rax, %r13                 /* %r13 = child pid            */
    subq    $16, %rsp                  /* scratch for status         */
    movq    $SYS_wait4, %rax
    movq    %r13, %rdi
    movq    %rsp, %rsi
    xorq    %rdx, %rdx
    xorq    %r10, %r10
    syscall
    addq    $16, %rsp
    cmpq    $0, %rax
    jl      fail_wait

    /* The child overwrote BOTH pages of the SHARED region with a
     * child sentinel = (0x9999 << 16) | iter. The parent maps the
     * SAME frames, so it must NOW read that sentinel back. */
    movq    g_iter(%rip), %rbx
    movq    $HS_CHILD, %rcx
    shlq    $16, %rcx
    orq     %rbx, %rcx                 /* %rcx = expected child value */
    movq    g_base(%rip), %rdx
    movq    0(%rdx), %rax
    cmpq    %rcx, %rax
    jne     fail_parent                /* still parent value -> not shared */
    movq    PAGE(%rdx), %rax
    cmpq    %rcx, %rax
    jne     fail_parent

    /* ---- 6. munmap the region ------------------------------------ */
    movq    $SYS_munmap, %rax
    movq    g_base(%rip), %rdi
    movq    $REGION_LEN, %rsi
    syscall
    testq   %rax, %rax
    jnz     fail_munmap

    /* ---- "MS: iter ok" ------------------------------------------- */
    movq    $SYS_write, %rax
    movq    $1, %rdi
    leaq    msg_iter_ok(%rip), %rsi
    movq    $len_iter_ok, %rdx
    syscall

    /* g_iter++ */
    movq    g_iter(%rip), %rax
    incq    %rax
    movq    %rax, g_iter(%rip)
    jmp     iter_loop

child_path:
    /* The child resumes with fresh registers — re-load everything it
     * needs from memory. g_base / g_iter survive the fork because the
     * ELF image is COW-shared; the handshake value lives in the
     * SHARED mmap page. */
    movq    g_base(%rip), %rdx         /* %rdx = region base          */
    movq    g_iter(%rip), %rbx         /* %rbx = iter                 */

    /* The child must SEE the parent's pre-fork handshake through the
     * shared frame: page 0 must equal (0x4444 << 16) | iter. */
    movq    $HS_PARENT, %rcx
    shlq    $16, %rcx
    orq     %rbx, %rcx                 /* %rcx = expected handshake   */
    movq    0(%rdx), %rax
    cmpq    %rcx, %rax
    jne     child_fail

    /* Overwrite BOTH pages with the child sentinel. */
    movq    $HS_CHILD, %rcx
    shlq    $16, %rcx
    orq     %rbx, %rcx                 /* %rcx = child sentinel       */
    movq    %rcx, 0(%rdx)
    movq    %rcx, PAGE(%rdx)

    movq    $SYS_exit_group, %rax
    xorq    %rdi, %rdi
    syscall
1:  jmp     1b

child_fail:
    movq    $SYS_write, %rax
    movq    $2, %rdi
    leaq    msg_fail_child(%rip), %rsi
    movq    $len_fail_child, %rdx
    syscall
    movq    $SYS_exit_group, %rax
    movq    $1, %rdi
    syscall
2:  jmp     2b

all_done:
    movq    $SYS_write, %rax
    movq    $1, %rdi
    leaq    msg_pass(%rip), %rsi
    movq    $len_pass, %rdx
    syscall
    movq    $SYS_exit_group, %rax
    xorq    %rdi, %rdi
    syscall
3:  jmp     3b

fail_mmap:
    leaq    msg_fail_mmap(%rip), %rsi
    movq    $len_fail_mmap, %rdx
    jmp     fail_emit
fail_fork:
    leaq    msg_fail_fork(%rip), %rsi
    movq    $len_fail_fork, %rdx
    jmp     fail_emit
fail_wait:
    leaq    msg_fail_wait(%rip), %rsi
    movq    $len_fail_wait, %rdx
    jmp     fail_emit
fail_parent:
    leaq    msg_fail_parent(%rip), %rsi
    movq    $len_fail_parent, %rdx
    jmp     fail_emit
fail_munmap:
    leaq    msg_fail_munmap(%rip), %rsi
    movq    $len_fail_munmap, %rdx
    jmp     fail_emit
fail_emit:
    movq    $SYS_write, %rax
    movq    $2, %rdi                   /* stderr                      */
    syscall
    movq    $SYS_exit_group, %rax
    movq    $1, %rdi
    syscall
4:  jmp     4b

    .section .bss
    .align 8
g_base:  .skip 8                       /* mmap region base, this iter */
g_iter:  .skip 8                       /* iteration index             */

    .section .rodata
    .align 8
msg_start:       .ascii "MS: start\n"
len_start = . - msg_start

msg_iter_ok:     .ascii "MS: iter ok\n"
len_iter_ok = . - msg_iter_ok

msg_pass:        .ascii "MS: PASS\n"
len_pass = . - msg_pass

msg_fail_mmap:   .ascii "MS: FAIL mmap\n"
len_fail_mmap = . - msg_fail_mmap

msg_fail_fork:   .ascii "MS: FAIL fork\n"
len_fail_fork = . - msg_fail_fork

msg_fail_wait:   .ascii "MS: FAIL wait\n"
len_fail_wait = . - msg_fail_wait

msg_fail_parent: .ascii "MS: FAIL parent did not see child write (not shared)\n"
len_fail_parent = . - msg_fail_parent

msg_fail_munmap: .ascii "MS: FAIL munmap\n"
len_fail_munmap = . - msg_fail_munmap

msg_fail_child:  .ascii "MS: FAIL child did not see parent handshake\n"
len_fail_child = . - msg_fail_child

    .section .note.GNU-stack,"",@progbits
