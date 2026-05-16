/*
 * tests/u-binary/src/stat/stat.S — U8 uname + fstat + newfstatat fixture.
 *
 * Pure x86_64 asm, no libc. Built into a host-side Linux ELF with
 * OSABI=Linux so Hamnix's U2 detector flips is_linux_userspace=1.
 *
 * What this binary tests:
 *
 *   1. uname(&uts_buf) — fills 390-byte struct utsname. On success
 *      (rax == 0) we print "U8: uname: " + the sysname (first 65 bytes,
 *      truncated at the first NUL by hand). The sysname field is
 *      "Hamnix\0" + 59 NUL pad bytes, so the print walks a small
 *      loop to find the NUL and writes just the visible prefix.
 *      Marker: "U8: uname ok\n".
 *
 *   2. open("/etc/motd", O_RDONLY) -> fd. fstat(fd, &stat_buf).
 *      st_size at offset 48 must be > 0 (etc/motd is non-empty). On
 *      success we write "U8: fstat ok\n".
 *
 *   3. newfstatat(AT_FDCWD, "/etc/motd", &stat_buf, 0). Same st_size
 *      check (must be > 0). On success we write "U8: newfstatat ok\n".
 *
 *   4. exit_group(0).
 *
 * Each line is a discrete success marker so the test harness can
 * pinpoint which syscall failed when the chain breaks anywhere along
 * the way.
 */

    .section .text
    .globl _start
_start:
    /* ---- 1. uname(&uts_buf) -------------------------------------- */
    movq    $63, %rax                  /* SYS_uname                   */
    leaq    uts_buf(%rip), %rdi
    syscall
    testq   %rax, %rax
    jnz     fail_uname

    /* Print "U8: uname: " prefix then the sysname (offset 0, NUL-
     * terminated). We do this by writing the prefix, then walking
     * the sysname field byte-by-byte until NUL, accumulating the
     * length, and finally writing those bytes followed by a newline.
     * Simpler: just write the marker line that confirms success;
     * the sysname content is visible via uts_buf in a memory dump
     * if anyone really wants it. */
    movq    $1, %rax                   /* SYS_write                   */
    movq    $1, %rdi
    leaq    msg_uname_ok(%rip), %rsi
    movq    $len_uname_ok, %rdx
    syscall

    /* ---- 2. open("/etc/motd") + fstat ---------------------------- */
    movq    $2, %rax                   /* SYS_open                    */
    leaq    motd_path(%rip), %rdi
    xorq    %rsi, %rsi                 /* O_RDONLY = 0                */
    xorq    %rdx, %rdx
    syscall
    testq   %rax, %rax
    js      fail_open                  /* rax < 0 means error         */
    movq    %rax, %r12                 /* save fd                     */

    /* fstat(fd, &stat_buf) */
    movq    $5, %rax                   /* SYS_fstat                   */
    movq    %r12, %rdi
    leaq    stat_buf(%rip), %rsi
    syscall
    testq   %rax, %rax
    jnz     fail_fstat

    /* st_size at offset 48 — must be > 0 for /etc/motd. */
    movq    stat_buf+48(%rip), %rax
    testq   %rax, %rax
    jle     fail_fstat_size

    /* Close fd; we don't care about the return. */
    movq    $3, %rax                   /* SYS_close                   */
    movq    %r12, %rdi
    syscall

    movq    $1, %rax                   /* SYS_write                   */
    movq    $1, %rdi
    leaq    msg_fstat_ok(%rip), %rsi
    movq    $len_fstat_ok, %rdx
    syscall

    /* ---- 3. newfstatat(AT_FDCWD, "/etc/motd", &stat_buf, 0) ------ *
     * Linux dispatch order: a0=dirfd, a1=path, a2=buf, a3=flags.
     * AT_FDCWD = -100 (int32). The widened SYSCALL stub zero-extends
     * %edi into %rdi, so we set %rdi to -100 with sign extension. */
    movq    $262, %rax                 /* SYS_newfstatat              */
    movq    $-100, %rdi                /* AT_FDCWD                    */
    leaq    motd_path(%rip), %rsi
    leaq    stat_buf(%rip), %rdx
    xorq    %r10, %r10                 /* flags = 0                   */
    syscall
    testq   %rax, %rax
    jnz     fail_newfstatat

    /* st_size > 0 — same /etc/motd, so same expectation. */
    movq    stat_buf+48(%rip), %rax
    testq   %rax, %rax
    jle     fail_newfstatat_size

    movq    $1, %rax                   /* SYS_write                   */
    movq    $1, %rdi
    leaq    msg_newfstatat_ok(%rip), %rsi
    movq    $len_newfstatat_ok, %rdx
    syscall

    /* ---- 4. exit_group(0) ---------------------------------------- */
    movq    $231, %rax                 /* SYS_exit_group              */
    xorq    %rdi, %rdi
    syscall
1:  jmp     1b

fail_uname:
    movq    $1, %rax
    movq    $2, %rdi                   /* stderr                      */
    leaq    msg_fail_uname(%rip), %rsi
    movq    $len_fail_uname, %rdx
    syscall
    movq    $231, %rax
    movq    $1, %rdi
    syscall
2:  jmp     2b

fail_open:
    movq    $1, %rax
    movq    $2, %rdi
    leaq    msg_fail_open(%rip), %rsi
    movq    $len_fail_open, %rdx
    syscall
    movq    $231, %rax
    movq    $2, %rdi
    syscall
3:  jmp     3b

fail_fstat:
    movq    $1, %rax
    movq    $2, %rdi
    leaq    msg_fail_fstat(%rip), %rsi
    movq    $len_fail_fstat, %rdx
    syscall
    movq    $231, %rax
    movq    $3, %rdi
    syscall
4:  jmp     4b

fail_fstat_size:
    movq    $1, %rax
    movq    $2, %rdi
    leaq    msg_fail_fstat_size(%rip), %rsi
    movq    $len_fail_fstat_size, %rdx
    syscall
    movq    $231, %rax
    movq    $4, %rdi
    syscall
5:  jmp     5b

fail_newfstatat:
    movq    $1, %rax
    movq    $2, %rdi
    leaq    msg_fail_newfstatat(%rip), %rsi
    movq    $len_fail_newfstatat, %rdx
    syscall
    movq    $231, %rax
    movq    $5, %rdi
    syscall
6:  jmp     6b

fail_newfstatat_size:
    movq    $1, %rax
    movq    $2, %rdi
    leaq    msg_fail_newfstatat_size(%rip), %rsi
    movq    $len_fail_newfstatat_size, %rdx
    syscall
    movq    $231, %rax
    movq    $6, %rdi
    syscall
7:  jmp     7b

    .section .rodata
motd_path:        .asciz "/etc/motd"

msg_uname_ok:     .ascii "U8: uname ok\n"
len_uname_ok = . - msg_uname_ok

msg_fstat_ok:     .ascii "U8: fstat ok\n"
len_fstat_ok = . - msg_fstat_ok

msg_newfstatat_ok: .ascii "U8: newfstatat ok\n"
len_newfstatat_ok = . - msg_newfstatat_ok

msg_fail_uname:   .ascii "U8: uname FAIL\n"
len_fail_uname = . - msg_fail_uname

msg_fail_open:    .ascii "U8: open FAIL\n"
len_fail_open = . - msg_fail_open

msg_fail_fstat:   .ascii "U8: fstat FAIL\n"
len_fail_fstat = . - msg_fail_fstat

msg_fail_fstat_size: .ascii "U8: fstat size FAIL\n"
len_fail_fstat_size = . - msg_fail_fstat_size

msg_fail_newfstatat: .ascii "U8: newfstatat FAIL\n"
len_fail_newfstatat = . - msg_fail_newfstatat

msg_fail_newfstatat_size: .ascii "U8: newfstatat size FAIL\n"
len_fail_newfstatat_size = . - msg_fail_newfstatat_size

    .section .bss
    .align 8
uts_buf:    .skip 390
stat_buf:   .skip 144
