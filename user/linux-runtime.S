/*
 * user/linux-runtime.S — freestanding x86_64 Linux userspace runtime for
 * the `x86_64-linux` Adder target.
 *
 * MIRRORS user/runtime.S (the Hamnix x86 user runtime) and the inline
 * `_start` the aarch64-linux backend emits — but targets the HOST Linux
 * kernel: standard Linux x86_64 syscall numbers (read=0, write=1, open=2,
 * close=3, lseek=8, exit=60) issued via the raw `syscall` instruction. No
 * libc, no C runtime, no Plan 9 / Hamnix kernel. The resulting ELF runs
 * directly on the developer's host Linux kernel.
 *
 * Syscall ABI (System V x86_64 syscall convention):
 *   %rax = syscall number
 *   %rdi, %rsi, %rdx, %r10, %r8, %r9 = args  (arg4 in %r10, NOT %rcx)
 *   return value in %rax
 *
 * The Adder codegen uses the System V *function* call convention
 * (rdi, rsi, rdx, rcx, r8, r9). For the <=3-arg wrappers below the
 * function arg regs (rdi/rsi/rdx) already line up with the syscall arg
 * regs, so each wrapper just loads the number into %rax and issues
 * `syscall`. lseek (3 args) likewise fits without a shuffle.
 *
 * Unlike user/runtime.S this is plain 64-bit code in a real elf64-x86-64
 * object (assembled `as --64`, no `.code64`-in-elf32 wrapper trick). It is
 * preprocessed (`gcc -c -DLINUX_ABI`) so user/syscall_nums.h's named
 * constants resolve.
 */

#define LINUX_ABI
#include "syscall_nums.h"

    /* --- Stack-protector runtime ------------------------------------
     * The Adder x86_64 codegen emits a canary load/store pair (and a
     * tail-call to __stack_chk_fail on mismatch) around every function it
     * tags `needs_canary` — any Array[N] local or `&local`. Both symbols
     * must resolve in every linked binary, so provide weak definitions
     * here; every x86_64-linux ELF pulls in linux-runtime.o. A binary that
     * wants a real PRNG-seeded guard can supply strong definitions.
     *
     * On mismatch, exit(134) — the SIGABRT exit code glibc uses. */
    .section .data
    .align 8
    .weak __stack_chk_guard
__stack_chk_guard:
    .quad 0xC0FFEEDEADBEEFC0

    .text
    .weak __stack_chk_fail
    .type __stack_chk_fail, @function
__stack_chk_fail:
    movq    $134, %rdi
    movq    $SYS_exit, %rax
    syscall
.L_chk_fail_hang:
    jmp     .L_chk_fail_hang
    .size __stack_chk_fail, .-__stack_chk_fail


    /* --- _start ------------------------------------------------------
     * Linux process entry. The kernel hands us, on the stack (no
     * registers set):
     *
     *   (%rsp)        argc
     *   8(%rsp)       argv[0]
     *   ...           argv[argc-1]
     *   ...           NULL
     *   ...           envp[0] ...
     *
     * We read argc into %rdi and &argv[0] into %rsi so main(argc, argv)
     * gets standard parameters (main functions that ignore them are
     * fine). Then call main, and pass its int32 return in %eax to
     * SYS_exit as the process exit code.
     *
     * %rsp is 16-byte aligned at process entry per the x86_64 SysV ABI;
     * `call main` pushes the 8-byte return address, leaving %rsp 16-byte
     * aligned + 8 inside main's prologue, exactly as a normal call site —
     * so any SSE spill in generated code stays correctly aligned.
     */
    .globl _start
    .type _start, @function
_start:
    xorq    %rbp, %rbp                /* mark outermost frame */
    movq    (%rsp), %rdi             /* argc */
    leaq    8(%rsp), %rsi            /* &argv[0] */
    call    main
    movslq  %eax, %rdi               /* sign-extend int32 status -> rdi */
    movq    $SYS_exit, %rax
    syscall
.L_start_hang:                       /* SYS_exit never returns; spin defensively */
    jmp     .L_start_hang
    .size _start, .-_start


    /* --- sys_read(fd, buf, count) -> int64 -------------------------- */
    .globl sys_read
    .type sys_read, @function
sys_read:
    movq    $SYS_read, %rax
    syscall
    ret
    .size sys_read, .-sys_read


    /* --- sys_write(fd, buf, count) -> int64 ------------------------- */
    .globl sys_write
    .type sys_write, @function
sys_write:
    movq    $SYS_write, %rax
    syscall
    ret
    .size sys_write, .-sys_write


    /* --- sys_open(path, flags, mode) -> int32 -----------------------
     * Linux open(2): a0=path, a1=flags (O_RDONLY=0, O_WRONLY=1,
     * O_CREAT=0x40, O_TRUNC=0x200, ...), a2=mode. 3 args fit rdi/rsi/rdx
     * directly. Returns the fd or -errno. */
    .globl sys_open
    .type sys_open, @function
sys_open:
    movq    $SYS_open, %rax
    syscall
    ret
    .size sys_open, .-sys_open


    /* --- sys_open_write(path) -> int32 ------------------------------
     * Mirrors user/runtime.S's SYS_OPEN_WRITE (open-or-create for write,
     * truncating an existing file). On the HOST this is a real Linux
     * open(2) with O_WRONLY|O_CREAT|O_TRUNC (0x241) and mode 0644 (0644
     * octal = 420). Only %rdi (path) is supplied by the caller; we load
     * the flags/mode ourselves so the SAME native source that writes a
     * file on-device also writes a real host file under x86_64-linux. */
    .globl sys_open_write
    .type sys_open_write, @function
sys_open_write:
    movq    $0x241, %rsi            /* O_WRONLY|O_CREAT|O_TRUNC */
    movq    $420, %rdx             /* mode 0644 */
    movq    $SYS_open, %rax
    syscall
    ret
    .size sys_open_write, .-sys_open_write


    /* --- sys_close(fd) -> int32 ------------------------------------- */
    .globl sys_close
    .type sys_close, @function
sys_close:
    movq    $SYS_close, %rax
    syscall
    ret
    .size sys_close, .-sys_close


    /* --- sys_lseek(fd, offset, whence) -> int64 --------------------- */
    .globl sys_lseek
    .type sys_lseek, @function
sys_lseek:
    movq    $SYS_lseek, %rax
    syscall
    ret
    .size sys_lseek, .-sys_lseek


    /* --- sys_mkdir(path) -> int32 -----------------------------------
     * The native primitive takes ONLY a path (mode is fixed on-device).
     * On the HOST we supply mode 0755 (=493) ourselves so the SAME native
     * source that mkdir()s on-device also creates a real host directory.
     * Returns 0 or -errno. */
    .globl sys_mkdir
    .type sys_mkdir, @function
sys_mkdir:
    movq    $493, %rsi              /* mode 0755 */
    movq    $SYS_mkdir, %rax
    syscall
    ret
    .size sys_mkdir, .-sys_mkdir


    /* --- sys_unlink(path) -> int32 ---------------------------------- */
    .globl sys_unlink
    .type sys_unlink, @function
sys_unlink:
    movq    $SYS_unlink, %rax
    syscall
    ret
    .size sys_unlink, .-sys_unlink


    /* --- sys_dup2(oldfd, newfd) -> int32 ---------------------------- */
    .globl sys_dup2
    .type sys_dup2, @function
sys_dup2:
    movq    $SYS_dup2, %rax
    syscall
    ret
    .size sys_dup2, .-sys_dup2


    /* --- Plan 9 / process-spawn primitives with NO host equivalent ---
     * lib/p9.ad (transitively imported by lib/hamfmcore.ad) references
     * these Hamnix-only syscalls. A host binary that only exercises the
     * browse core's FILE ops (mkdir/touch/unlink/rename via the wrappers
     * above) never CALLS them, but they must RESOLVE for the link to
     * succeed. Provide stubs that fail closed (return -1); if a host path
     * ever reaches one it errors cleanly rather than corrupting state. */
    .globl sys_rfork
    .type sys_rfork, @function
sys_rfork:
    movq    $-1, %rax
    ret
    .size sys_rfork, .-sys_rfork

    .globl sys_execve_env
    .type sys_execve_env, @function
sys_execve_env:
    movq    $-1, %rax
    ret
    .size sys_execve_env, .-sys_execve_env

    .globl sys_fdbind
    .type sys_fdbind, @function
sys_fdbind:
    movq    $-1, %rax
    ret
    .size sys_fdbind, .-sys_fdbind

    .globl sys_chan_dir_mode
    .type sys_chan_dir_mode, @function
sys_chan_dir_mode:
    movq    $-1, %rax
    ret
    .size sys_chan_dir_mode, .-sys_chan_dir_mode

    .globl sys_listdir_records
    .type sys_listdir_records, @function
sys_listdir_records:
    movq    $-1, %rax
    ret
    .size sys_listdir_records, .-sys_listdir_records

    .globl sys_stat_p9
    .type sys_stat_p9, @function
sys_stat_p9:
    movq    $-1, %rax
    ret
    .size sys_stat_p9, .-sys_stat_p9

    /* --- sys_resolve(hostname, hlen) -> int64 ----------------------
       Native-ABI in-kernel DNS resolve (Hamnix syscall 269). The host
       Linux kernel has no such resolver, so this is a host stub that
       reports failure — it exists only so http9.ad (which imports it)
       links for the x86_64-linux host unit tests. On-device the real
       wrapper lives in the native user runtime, not here. */
    .globl sys_resolve
    .type sys_resolve, @function
sys_resolve:
    movq    $-1, %rax
    ret
    .size sys_resolve, .-sys_resolve


    /* --- sys_exit(code) — never returns ----------------------------- */
    .globl sys_exit
    .type sys_exit, @function
sys_exit:
    movq    $SYS_exit, %rax
    syscall
.L_exit_hang:
    jmp     .L_exit_hang
    .size sys_exit, .-sys_exit

    /* Non-executable stack marker (suppress ld's executable-stack warn). */
    .section .note.GNU-stack, "", @progbits
