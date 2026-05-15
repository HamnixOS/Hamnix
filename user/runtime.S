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


    /* --- sys_open_write(path) -> int32 -------------------------------
     * Open-or-create for write. Truncates an existing file. Tmpfs
     * paths (/tmp/*) are the only writable target as of M16.37. */
    .globl sys_open_write
    .type sys_open_write, @function
sys_open_write:
    movq    $13, %rax               /* SYS_OPEN_WRITE */
    syscall
    ret
    .size sys_open_write, .-sys_open_write


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


    /* --- sys_spawn(path, argv, stdin_fd, stdout_fd) -> int32 --------
     * 4-arg syscall. SysV places arg 4 in %rcx, but the syscall
     * ABI reserves %rcx for the user RIP and uses %r10 for arg 4.
     * Shuffle %rcx -> %r10 before `syscall`. The next syscall whose
     * caller has >=4 args needs the same dance. */
    .globl sys_spawn
    .type sys_spawn, @function
sys_spawn:
    movq    %rcx, %r10              /* arg 4: stdout_fd */
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


    /* --- sys_pipe(int fds[2]) -> int32 -------------------------------
     * Returns 0 on success; fds[0] = read end, fds[1] = write end. */
    .globl sys_pipe
    .type sys_pipe, @function
sys_pipe:
    movq    $14, %rax               /* SYS_PIPE */
    syscall
    ret
    .size sys_pipe, .-sys_pipe


    /* --- sys_kill(pid, sig) -> int32 ---------------------------------
     * Post `sig` into pid's pending-signal bitmap. Default
     * disposition for every signal is TERM with exit code 128+sig
     * — no per-process handlers yet. */
    .globl sys_kill
    .type sys_kill, @function
sys_kill:
    movq    $15, %rax               /* SYS_KILL */
    syscall
    ret
    .size sys_kill, .-sys_kill


    /* --- sys_dup(oldfd) -> int32 -------------------------------------
     * Allocate the smallest free fd; copy oldfd's backing into it.
     * Pipe refcounts get bumped so closing oldfd later doesn't
     * affect the dup. Returns the new fd or -EBADF / -EMFILE. */
    .globl sys_dup
    .type sys_dup, @function
sys_dup:
    movq    $16, %rax               /* SYS_DUP */
    syscall
    ret
    .size sys_dup, .-sys_dup


    /* --- sys_dup2(oldfd, newfd) -> int32 -----------------------------
     * Close newfd (if open) and copy oldfd into it. POSIX behaviour:
     * if oldfd == newfd this is a no-op and returns newfd. */
    .globl sys_dup2
    .type sys_dup2, @function
sys_dup2:
    movq    $17, %rax               /* SYS_DUP2 */
    syscall
    ret
    .size sys_dup2, .-sys_dup2


    /* --- sys_listdir(path, buf, count) -> int64 ----------------------
     * Pack directory entries from `path` as "NAME.EXT\n" lines into
     * `buf`, up to `count` bytes. Returns bytes written, or
     * -errno. /mnt/* only for now. */
    .globl sys_listdir
    .type sys_listdir, @function
sys_listdir:
    movq    $18, %rax               /* SYS_LISTDIR */
    syscall
    ret
    .size sys_listdir, .-sys_listdir
