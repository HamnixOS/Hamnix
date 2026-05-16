/*
 * tests/u-binary/src/access/access.S — U9 access + stat + lstat + openat
 *                                       fixture.
 *
 * Pure x86_64 asm, no libc. Built into a host-side Linux ELF with
 * OSABI=Linux so Hamnix's U2 detector flips is_linux_userspace=1.
 *
 * What this binary tests, in order:
 *
 *   1. access("/etc/motd", F_OK)        -> rax == 0
 *      Marker: "U9: access ok\n".
 *   2. access("/no/such/file", F_OK)    -> rax == -2 (-ENOENT)
 *      Marker: "U9: access ENOENT ok\n".
 *   3. stat("/etc/motd", &statbuf)      -> rax == 0
 *      Marker: "U9: stat ok\n".
 *   4. lstat("/etc/motd", &statbuf)     -> rax == 0
 *      Marker: "U9: lstat ok\n".
 *   5. openat(AT_FDCWD, "/etc/motd", O_RDONLY)
 *                                       -> rax >= 0 (fd)
 *      Marker: "U9: openat ok\n".
 *      We then close(rax) to release the fd; the test harness only
 *      cares about the marker.
 *   6. exit_group(0).
 *
 * Each line is a discrete success marker so the test harness can
 * pinpoint which syscall failed when the chain breaks anywhere along
 * the way. On any failure we write a "U9: <name> FAIL" line to stderr
 * and exit with a distinct non-zero status (1..5) so the harness can
 * decode the failure point even from a truncated capture.
 */

    .section .text
    .globl _start
_start:
    /* ---- 1. access("/etc/motd", F_OK) ---------------------------- */
    movq    $21, %rax                  /* SYS_access                  */
    leaq    motd_path(%rip), %rdi
    xorq    %rsi, %rsi                 /* mode = F_OK = 0             */
    syscall
    testq   %rax, %rax
    jnz     fail_access

    movq    $1, %rax                   /* SYS_write                   */
    movq    $1, %rdi
    leaq    msg_access_ok(%rip), %rsi
    movq    $len_access_ok, %rdx
    syscall

    /* ---- 2. access("/no/such/file", F_OK) ------------------------ *
     * Must return -ENOENT (-2). The kernel-side _u_access body
     * collapses any resolve_path/vfs_open failure to ELINUX_NOENT,
     * so a missing path is the same as a malformed path here.
     */
    movq    $21, %rax                  /* SYS_access                  */
    leaq    nope_path(%rip), %rdi
    xorq    %rsi, %rsi
    syscall
    cmpq    $-2, %rax
    jne     fail_access_nope

    movq    $1, %rax
    movq    $1, %rdi
    leaq    msg_access_enoent_ok(%rip), %rsi
    movq    $len_access_enoent_ok, %rdx
    syscall

    /* ---- 3. stat("/etc/motd", &statbuf) -------------------------- */
    movq    $4, %rax                   /* SYS_stat                    */
    leaq    motd_path(%rip), %rdi
    leaq    stat_buf(%rip), %rsi
    syscall
    testq   %rax, %rax
    jnz     fail_stat

    movq    $1, %rax
    movq    $1, %rdi
    leaq    msg_stat_ok(%rip), %rsi
    movq    $len_stat_ok, %rdx
    syscall

    /* ---- 4. lstat("/etc/motd", &statbuf) ------------------------- *
     * Hamnix has no symlinks, so lstat is identical to stat. We still
     * dispatch SYS_lstat (6) here so the kernel's dispatch ladder is
     * exercised — a regression that drops SYS_lstat back to -ENOSYS
     * shows up as rax = -38 here. */
    movq    $6, %rax                   /* SYS_lstat                   */
    leaq    motd_path(%rip), %rdi
    leaq    stat_buf(%rip), %rsi
    syscall
    testq   %rax, %rax
    jnz     fail_lstat

    movq    $1, %rax
    movq    $1, %rdi
    leaq    msg_lstat_ok(%rip), %rsi
    movq    $len_lstat_ok, %rdx
    syscall

    /* ---- 5. openat(AT_FDCWD, "/etc/motd", O_RDONLY) -------------- *
     * Linux dispatch order: a0=dirfd, a1=path, a2=flags, a3=mode.
     * AT_FDCWD = -100 (int32). The widened SYSCALL stub zero-extends
     * %edi into %rdi, so we set %rdi to -100 via sign-extension
     * (`movq $-100, %rdi`) and the int32 cast on the kernel side
     * recovers the right negative value.
     */
    movq    $257, %rax                 /* SYS_openat                  */
    movq    $-100, %rdi                /* AT_FDCWD                    */
    leaq    motd_path(%rip), %rsi
    xorq    %rdx, %rdx                 /* O_RDONLY = 0                */
    xorq    %r10, %r10                 /* mode = 0                    */
    syscall
    testq   %rax, %rax
    js      fail_openat                /* rax < 0 means error         */
    movq    %rax, %r12                 /* save fd for close           */

    movq    $1, %rax
    movq    $1, %rdi
    leaq    msg_openat_ok(%rip), %rsi
    movq    $len_openat_ok, %rdx
    syscall

    /* close(fd) — best-effort, no marker. */
    movq    $3, %rax                   /* SYS_close                   */
    movq    %r12, %rdi
    syscall

    /* ---- 6. exit_group(0) ---------------------------------------- */
    movq    $231, %rax                 /* SYS_exit_group              */
    xorq    %rdi, %rdi
    syscall
1:  jmp     1b

fail_access:
    movq    $1, %rax
    movq    $2, %rdi                   /* stderr                      */
    leaq    msg_fail_access(%rip), %rsi
    movq    $len_fail_access, %rdx
    syscall
    movq    $231, %rax
    movq    $1, %rdi
    syscall
2:  jmp     2b

fail_access_nope:
    movq    $1, %rax
    movq    $2, %rdi
    leaq    msg_fail_access_nope(%rip), %rsi
    movq    $len_fail_access_nope, %rdx
    syscall
    movq    $231, %rax
    movq    $2, %rdi
    syscall
3:  jmp     3b

fail_stat:
    movq    $1, %rax
    movq    $2, %rdi
    leaq    msg_fail_stat(%rip), %rsi
    movq    $len_fail_stat, %rdx
    syscall
    movq    $231, %rax
    movq    $3, %rdi
    syscall
4:  jmp     4b

fail_lstat:
    movq    $1, %rax
    movq    $2, %rdi
    leaq    msg_fail_lstat(%rip), %rsi
    movq    $len_fail_lstat, %rdx
    syscall
    movq    $231, %rax
    movq    $4, %rdi
    syscall
5:  jmp     5b

fail_openat:
    movq    $1, %rax
    movq    $2, %rdi
    leaq    msg_fail_openat(%rip), %rsi
    movq    $len_fail_openat, %rdx
    syscall
    movq    $231, %rax
    movq    $5, %rdi
    syscall
6:  jmp     6b

    .section .rodata
motd_path:        .asciz "/etc/motd"
nope_path:        .asciz "/no/such/file"

msg_access_ok:        .ascii "U9: access ok\n"
len_access_ok = . - msg_access_ok

msg_access_enoent_ok: .ascii "U9: access ENOENT ok\n"
len_access_enoent_ok = . - msg_access_enoent_ok

msg_stat_ok:          .ascii "U9: stat ok\n"
len_stat_ok = . - msg_stat_ok

msg_lstat_ok:         .ascii "U9: lstat ok\n"
len_lstat_ok = . - msg_lstat_ok

msg_openat_ok:        .ascii "U9: openat ok\n"
len_openat_ok = . - msg_openat_ok

msg_fail_access:      .ascii "U9: access FAIL\n"
len_fail_access = . - msg_fail_access

msg_fail_access_nope: .ascii "U9: access ENOENT FAIL\n"
len_fail_access_nope = . - msg_fail_access_nope

msg_fail_stat:        .ascii "U9: stat FAIL\n"
len_fail_stat = . - msg_fail_stat

msg_fail_lstat:       .ascii "U9: lstat FAIL\n"
len_fail_lstat = . - msg_fail_lstat

msg_fail_openat:      .ascii "U9: openat FAIL\n"
len_fail_openat = . - msg_fail_openat

    .section .bss
    .align 8
stat_buf:   .skip 144
