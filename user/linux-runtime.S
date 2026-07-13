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
