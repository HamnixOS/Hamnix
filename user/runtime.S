/*
 * user/runtime.S - Hamnix userspace runtime.
 *
 * Provides the _start entry point and a small set of syscall wrappers
 * that Hamnix user programs can call as ordinary `extern def` symbols.
 *
 * Calling convention mismatch (and why these wrappers exist):
 *   Hamnix generated code uses System V AMD64 (rdi, rsi, rdx, rcx, r8, r9
 *   for the first six integer/pointer args, return in rax).
 *   Our kernel's syscall entry expects:
 *     %rax = syscall number
 *     %rdi, %rsi, %rdx, %r10, %r8, %r9 = args  (note: r10 not rcx)
 *     return in %rax
 *   For the wrappers below we never have more than three args, so the
 *   SysV-arg-regs and the syscall-arg-regs align (rdi/rsi/rdx). We
 *   just load the syscall number into %rax and emit `syscall`.
 *
 * Position independence:
 *   Like user/init.S this file is 64-bit code in an elf32-i386 wrapper
 *   (`as --32` with a leading `.code64`). All symbol references are
 *   RIP-relative — the file contains no asm symbol references that
 *   would need a 64-bit absolute relocation.
 */

    .code64
    .section .text, "ax"

    /* --- _start ------------------------------------------------------
     * Kernel hands us a freshly-allocated user stack already aligned to
     * 16 bytes (see arch/x86/kernel/sched/core.py:create_user_task and
     * the iretq frame built by start_first_task). We simply call main()
     * and pass its return value (in %eax → zero-extended %rdi) to
     * SYS_EXIT.
     *
     * If main() never returns (e.g. it calls sys_exit itself) the
     * trailing exit is unreached; that's fine.
     */
    .globl _start
_start:
    /* The kernel pre-loaded %rdi = argc, %rsi = argv before iretq/
     * sysretq landed us here (see arch/x86/kernel/sched/core.ad's
     * _build_initial_kstack and syscall_64.S's do_execve_finish).
     * `call main` does not clobber rdi/rsi beforehand, so they
     * forward directly as main()'s first two SysV arguments. Main
     * functions that don't declare argc/argv simply ignore them. */
    call    main
    /* main returns int32 in %eax. Sign-extend to %rdi so SYS_EXIT
     * sees a clean exit code. */
    movslq  %eax, %rdi
    movq    $1, %rax                /* SYS_EXIT */
    syscall
.L_start_hang:
    /* Defensive: if SYS_EXIT ever returns (it shouldn't), spin. */
    jmp     .L_start_hang


    /* --- sys_write(fd, buf, count) -> int64 -------------------------- */
    .globl sys_write
    .type sys_write, @function
sys_write:
    movq    $8, %rax                /* SYS_WRITE */
    syscall
    ret
    .size sys_write, .-sys_write


    /* --- sys_read(fd, buf, count) -> int64 --------------------------- */
    .globl sys_read
    .type sys_read, @function
sys_read:
    movq    $6, %rax                /* SYS_READ */
    syscall
    ret
    .size sys_read, .-sys_read


    /* --- sys_open(path) -> int32 ------------------------------------- */
    .globl sys_open
    .type sys_open, @function
sys_open:
    movq    $5, %rax                /* SYS_OPEN */
    syscall
    ret
    .size sys_open, .-sys_open


    /* --- sys_close(fd) -> int32 -------------------------------------- */
    .globl sys_close
    .type sys_close, @function
sys_close:
    movq    $7, %rax                /* SYS_CLOSE */
    syscall
    ret
    .size sys_close, .-sys_close


    /* --- sys_exit(code) ---------------------------------------------- */
    .globl sys_exit
    .type sys_exit, @function
sys_exit:
    movq    $1, %rax                /* SYS_EXIT */
    syscall
    /* SYS_EXIT does not return. Spin if it ever does. */
.L_exit_hang:
    jmp     .L_exit_hang
    .size sys_exit, .-sys_exit


    /* --- sys_putc(c) ------------------------------------------------- */
    .globl sys_putc
    .type sys_putc, @function
sys_putc:
    movq    $0, %rax                /* SYS_PUTC */
    syscall
    ret
    .size sys_putc, .-sys_putc


    /* --- sys_lseek(fd, offset, whence) -> int64 ---------------------- */
    .globl sys_lseek
    .type sys_lseek, @function
sys_lseek:
    movq    $9, %rax                /* SYS_LSEEK */
    syscall
    ret
    .size sys_lseek, .-sys_lseek


    /* --- sys_get_jiffies() -> uint64 --------------------------------- */
    .globl sys_get_jiffies
    .type sys_get_jiffies, @function
sys_get_jiffies:
    movq    $2, %rax                /* SYS_GET_JIFFIES */
    syscall
    ret
    .size sys_get_jiffies, .-sys_get_jiffies


    /* --- sys_getpid() -> int32 --------------------------------------- */
    .globl sys_getpid
    .type sys_getpid, @function
sys_getpid:
    movq    $4, %rax                /* SYS_GETPID */
    syscall
    ret
    .size sys_getpid, .-sys_getpid


    /* --- sys_execve(path, argv) -- never returns on success ---------- */
    .globl sys_execve
    .type sys_execve, @function
sys_execve:
    movq    $10, %rax               /* SYS_EXECVE */
    syscall
    ret                             /* only reached on failure */
    .size sys_execve, .-sys_execve


    /* --- sys_spawn(path, argv) -> int32 (child pid or -errno) ------- */
    .globl sys_spawn
    .type sys_spawn, @function
sys_spawn:
    movq    $11, %rax               /* SYS_SPAWN */
    syscall
    ret
    .size sys_spawn, .-sys_spawn


    /* --- sys_waitpid(pid) -> int64 (child exit_code or -errno) ------ */
    .globl sys_waitpid
    .type sys_waitpid, @function
sys_waitpid:
    movq    $12, %rax               /* SYS_WAITPID */
    syscall
    ret
    .size sys_waitpid, .-sys_waitpid
