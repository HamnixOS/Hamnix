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

    /* --- Stack-protector runtime (user side) -------------------------
     * V0 stack-canary support. The Adder x86_64 codegen emits a
     * canary load/store pair around every function it tags
     * `needs_canary` (Array[N>=8] local or any &local — same
     * heuristic gcc's -fstack-protector-strong uses). The prologue
     * references __stack_chk_guard(%rip) and a mismatch tail-call's
     * __stack_chk_fail. Both symbols must resolve in every user
     * binary's link, so we provide weak definitions here in
     * runtime.S — every user ELF picks up runtime.o, so the
     * symbols are always present. A user binary that wants
     * stronger semantics (e.g. a real PRNG-seeded guard) can
     * supply a strong definition and the linker preference rules
     * pick that one instead.
     *
     * On mismatch, sys_exit(134) — Linux's SIGABRT exit code, what
     * glibc's __stack_chk_fail uses. The shell + initramfs runner
     * see exit code 134 and the test script greps for it as the
     * "canary detected" marker.
     */
    .weak __stack_chk_guard
    .section .data
    .align 8
__stack_chk_guard:
    /* Same C0FFEE..C0 magic as kernel/stack_protect.ad's pre-init
     * value. User binaries don't have a __stack_chk_init phase
     * (no PRNG access from CPL 3 yet), so the magic IS the live
     * guard for the binary's whole lifetime. */
    .quad 0xC0FFEEDEADBEEFC0

    .section .text, "ax"
    .weak __stack_chk_fail
    .type __stack_chk_fail, @function
__stack_chk_fail:
    /* Move 134 (Linux SIGABRT exit code) into %rdi, sys_exit. The
     * code path is a tail-call from the canary epilogue; the
     * caller's frame is already partly-corrupted (that's how we
     * got here), so making a fresh syscall is the only safe
     * forward action. SYS_EXIT does not return; defensively spin
     * if it ever does. */
    movq    $134, %rdi
    movq    $1, %rax                /* SYS_EXIT */
    syscall
.L_chk_fail_hang:
    jmp     .L_chk_fail_hang
    .size __stack_chk_fail, .-__stack_chk_fail


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


    /* --- sys_spawn(path, argv, stdin_fd, stdout_fd, envp) -> int32 --
     * 5-arg syscall. SysV places arg 4 in %rcx and arg 5 in %r8,
     * but the syscall ABI reserves %rcx for the user RIP and uses
     * %r10 for arg 4. Shuffle %rcx -> %r10 before `syscall`; %r8
     * (arg 5: envp) already lines up between the two ABIs.
     * U17: envp is a Ptr[uint64] NULL-terminated array of cstring
     * pointers to "NAME=VALUE\0", or 0 for empty env. */
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


    /* --- sys_socketpair(domain, type, protocol, sv[2]) -> int32 -----
     * V5: bidirectional fd pair — both fds are read/write. Picked
     * Linux syscall number 53 so binaries that expect Linux's
     * socketpair(2) call site land here unchanged. 4-arg syscall:
     * SysV places arg 4 in %rcx, but the syscall ABI reserves %rcx
     * for the user RIP and wants arg 4 in %r10. Shuffle %rcx -> %r10
     * before SYSCALL (same pattern as sys_spawn / sys_mount). */
    .globl sys_socketpair
    .type sys_socketpair, @function
sys_socketpair:
    movq    %rcx, %r10              /* arg 4: sv -> r10 for syscall ABI */
    movq    $53, %rax               /* SYS_SOCKETPAIR */
    syscall
    ret
    .size sys_socketpair, .-sys_socketpair


    /* --- sys_socket(domain, type, protocol) -> int32 ----------------
     * U-socket: native-ABI entry point to the same socket(2) bridge
     * the Linux ABI exposes at number 41. A native Adder user binary
     * (built with this runtime.S) reaches the in-kernel TCP stack via
     * SYS_SOCKET (41) -> _u_socket in arch/x86/kernel/syscall.ad. V0
     * supports AF_INET + SOCK_STREAM only. SysV first three arg regs
     * (%rdi/%rsi/%rdx) align with the syscall ABI's a0/a1/a2 — no
     * shuffle needed. */
    .globl sys_socket
    .type sys_socket, @function
sys_socket:
    movq    $41, %rax               /* SYS_SOCKET */
    syscall
    ret
    .size sys_socket, .-sys_socket


    /* --- sys_connect(fd, addr, addrlen) -> int32 --------------------
     * U-socket: native-ABI connect(2). Drives a real TCP active open
     * through drivers/net/tcp.ad via SYS_CONNECT (42) -> _u_connect.
     * `addr` points at a 16-byte struct sockaddr_in. Three args fit
     * the SysV/syscall-ABI overlap directly. */
    .globl sys_connect
    .type sys_connect, @function
sys_connect:
    movq    $42, %rax               /* SYS_CONNECT */
    syscall
    ret
    .size sys_connect, .-sys_connect


    /* --- sys_sock_bind(fd, addr, addrlen) -> int32 ------------------
     * U-socket server side: native-ABI bind(2). Records the bound port
     * on the socket fd's backing record via SYS_BIND_SOCK (49) ->
     * _u_bind. NOTE the name: this is socket bind, NOT the Plan 9
     * namespace sys_bind (syscall 257) defined below — the two share
     * the C name `bind` in POSIX/Plan 9 but are wholly different
     * syscalls, so the socket one carries the _sock suffix. `addr`
     * points at a 16-byte struct sockaddr_in. Three args fit the
     * SysV/syscall-ABI overlap directly. */
    .globl sys_sock_bind
    .type sys_sock_bind, @function
sys_sock_bind:
    movq    $49, %rax               /* SYS_BIND_SOCK */
    syscall
    ret
    .size sys_sock_bind, .-sys_sock_bind


    /* --- sys_listen(fd, backlog) -> int32 ---------------------------
     * U-socket server side: native-ABI listen(2). Calls the in-kernel
     * tcp_listen for the port recorded by sys_sock_bind via
     * SYS_LISTEN_SOCK (50) -> _u_listen, transitioning the socket to
     * the LISTENING state. Two args fit the ABI overlap directly. */
    .globl sys_listen
    .type sys_listen, @function
sys_listen:
    movq    $50, %rax               /* SYS_LISTEN_SOCK */
    syscall
    ret
    .size sys_listen, .-sys_listen


    /* --- sys_accept(fd, addr, addrlen) -> int32 ---------------------
     * U-socket server side: native-ABI accept(2). Blocks (bounded
     * poll) on a LISTENING socket via SYS_ACCEPT_SOCK (43) ->
     * _u_accept until the in-kernel TCP stack completes a handshake,
     * then returns a fresh socket fd for the accepted connection.
     * `addr` (peer sockaddr out, may be NULL) / `addrlen` are filled
     * when supplied. Three args fit the ABI overlap directly. */
    .globl sys_accept
    .type sys_accept, @function
sys_accept:
    movq    $43, %rax               /* SYS_ACCEPT_SOCK */
    syscall
    ret
    .size sys_accept, .-sys_accept


    /* --- sys_resolve(hostname, len) -> int64 ------------------------
     * U-resolve: native-ABI hostname -> IPv4. Hands a NUL-terminated
     * hostname (%rdi) + its length (%rsi) to the in-kernel DNS
     * resolver via SYS_RESOLVE (269) -> dns_lookup. On success %rax
     * holds the resolved IPv4 packed big-endian in the low 32 bits
     * (octet 0 in bits 31:24); on failure %rax is a negative errno
     * (-2 == cannot resolve). Two args fit the SysV/syscall-ABI
     * overlap directly — no shuffle. */
    .globl sys_resolve
    .type sys_resolve, @function
sys_resolve:
    movq    $269, %rax              /* SYS_RESOLVE */
    syscall
    ret
    .size sys_resolve, .-sys_resolve


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


    /* --- sys_chdir(path) -> int32 ------------------------------------ */
    .globl sys_chdir
    .type sys_chdir, @function
sys_chdir:
    movq    $19, %rax               /* SYS_CHDIR */
    syscall
    ret
    .size sys_chdir, .-sys_chdir


    /* --- sys_getcwd(buf, count) -> int64 -----------------------------
     * Copies the calling task's CWD into buf as a NUL-terminated
     * string. Returns bytes written (including the NUL). */
    .globl sys_getcwd
    .type sys_getcwd, @function
sys_getcwd:
    movq    $20, %rax               /* SYS_GETCWD */
    syscall
    ret
    .size sys_getcwd, .-sys_getcwd


    /* --- sys_unlink(path) -> int32 -----------------------------------
     * Remove a name from the filesystem. tmpfs frees the slot;
     * other backings return -EROFS until their write paths land. */
    .globl sys_unlink
    .type sys_unlink, @function
sys_unlink:
    movq    $21, %rax               /* SYS_UNLINK */
    syscall
    ret
    .size sys_unlink, .-sys_unlink


    /* --- sys_mkdir(path) -> int32 ------------------------------------
     * No-op stub at this scale (tmpfs is flat). Returns 0 so
     * userland `mkdir foo` doesn't error out before the real
     * directory machinery exists. */
    .globl sys_mkdir
    .type sys_mkdir, @function
sys_mkdir:
    movq    $22, %rax               /* SYS_MKDIR */
    syscall
    ret
    .size sys_mkdir, .-sys_mkdir


    /* --- sys_errstr(buf, nbuf) -> int32 -----------------------------
     * Plan 9-shape per-process error string read/write. Reads the
     * current error message into `buf` (NUL-terminated, truncated to
     * `nbuf-1` bytes). If `buf[0]` is non-zero on entry, the call ALSO
     * installs `buf`'s contents as the new current error (swap
     * semantics). Used as the foundation for every other Plan 9
     * syscall's error reporting. See docs/native-api.md (265) and
     * sys/src/9/port/error.ad for the contract. */
    .globl sys_errstr
    .type sys_errstr, @function
sys_errstr:
    movq    $265, %rax              /* SYS_ERRSTR */
    syscall
    ret
    .size sys_errstr, .-sys_errstr


    /* --- sys_bind(new, old, flag) -> int32 --------------------------
     * Phase C / M16.107: Plan 9-shape namespace primitive. Graft
     * path `new` onto path `old` in the calling task's namespace;
     * after this, opens of `new/x` look up `old/x` via the kernel's
     * resolve_path -> chan_resolve_prefix hook (`fs/vfs.ad`).
     *
     * flag = MREPL (0) / MBEFORE / MAFTER / MCREATE / MCACHE bits per
     * docs/native-api.md; Phase C records the bit but only MREPL is
     * honoured at resolve time (union mounts come in Phase D).
     *
     * Returns 0 on success, -1 on failure with the per-process error
     * string set by syschan.ad (`bind failed: ...`).  SysV first
     * three arg regs (%rdi/%rsi/%rdx) align with the syscall ABI's
     * a0/a1/a2 — no shuffle needed. */
    .globl sys_bind
    .type sys_bind, @function
sys_bind:
    movq    $257, %rax              /* SYS_BIND */
    syscall
    ret
    .size sys_bind, .-sys_bind


    /* --- sys_mount(srvfd, afd, old, flag, spec) -> int32 ------------
     * Phase C / M16.107: attach a 9P file server (reachable over the
     * open `srvfd`) at path `old`. `afd` is the fauth(2) channel, or
     * -1 to skip auth (the only shape Hamnix supports today — fauth
     * itself doesn't exist yet). `spec` is the server-specific attach
     * string ("" for the default tree).
     *
     * 5-arg syscall. SysV places arg 4 in %rcx, arg 5 in %r8; the
     * syscall ABI reserves %rcx for the user RIP and uses %r10 for
     * arg 4. Shuffle %rcx -> %r10 before SYSCALL; %r8 (arg 5: spec)
     * already aligns between the two ABIs. Returns 0 on success or
     * -1 with errstr set (`mount failed: ...`). */
    .globl sys_mount
    .type sys_mount, @function
sys_mount:
    movq    %rcx, %r10              /* arg 4: flag -> r10 for syscall ABI */
    movq    $258, %rax              /* SYS_MOUNT */
    syscall
    ret
    .size sys_mount, .-sys_mount


    /* --- sys_unmount(new, old) -> int32 -----------------------------
     * Phase C / M16.107: remove a binding. `new == NULL` (0) unbinds
     * every entry visible at `old`; otherwise removes the specific
     * `new -> old` edge from a union mount. Returns 0 on success
     * (>= 1 entry removed) or -1 with errstr `not mounted`. */
    .globl sys_unmount
    .type sys_unmount, @function
sys_unmount:
    movq    $259, %rax              /* SYS_UNMOUNT */
    syscall
    ret
    .size sys_unmount, .-sys_unmount


    /* --- sys_rfork(flags) -> int32 ----------------------------------
     * Phase C / M16.98: Plan 9-shape process / namespace primitive.
     * SysV passes `flags` in %rdi (also the syscall a0 slot). do_rfork
     * additionally needs the parent's user-side %rbp so it can patch
     * the child's initial __switch_to stack image — without that the
     * child's first RBP-relative local read after rfork() goes to the
     * parent's stack page. We stash %rbp into %r9 (syscall a5) before
     * the SYSCALL instruction; syscall_64.S forwards a5 verbatim to
     * do_syscall, which hands it to do_rfork as its second arg.
     *
     * Behaviour mirrors 9front's rfork(2):
     *   * RFPROC set:    returns child pid in parent, 0 in child.
     *   * RFPROC clear:  mutates current task in place; returns 0.
     *   * On error:      returns -EAGAIN / -ENOSYS (negative int32). */
    .globl sys_rfork
    .type sys_rfork, @function
sys_rfork:
    movq    %rbp, %r9               /* a5 = parent user %rbp */
    movq    $256, %rax              /* SYS_RFORK */
    syscall
    ret
    .size sys_rfork, .-sys_rfork


    /* --- sys_srv_post(name, srvfd) -> int32 -------------------------
     * Phase D / V4: publish (name -> srvfd) into the kernel `srv`
     * table. `name` is a NUL-terminated leaf ("hamwd", not
     * "/srv/hamwd"); `srvfd` is an fd open in the calling task.
     * Returns 0 on success or -1 with errstr ("srv: bad name",
     * "srv: bad fd", "srv: name in use or table full"). SysV first
     * two arg regs (%rdi/%rsi) align with the syscall ABI's a0/a1
     * — no shuffle needed. Mirrors the sys_bind/sys_mount wrappers
     * above for shape and comment style. */
    .globl sys_srv_post
    .type sys_srv_post, @function
sys_srv_post:
    movq    $275, %rax              /* SYS_SRV_POST */
    syscall
    ret
    .size sys_srv_post, .-sys_srv_post


    /* --- sys_srv_open(name) -> int32 --------------------------------
     * Phase D / V4: open a posted `srv` name. Returns a fresh fd in
     * the CALLER's fd table (the kernel copy_fd_entry's the poster's
     * underlying file/pipe into the caller's table), or -1 with
     * errstr ("srv: not posted", "srv: kernel-only", "srv: dup
     * failed"). Once you have the fd you typically pass it straight
     * to sys_mount + close it, per the docs/native-api.md service-
     * consumer idiom. */
    .globl sys_srv_open
    .type sys_srv_open, @function
sys_srv_open:
    movq    $276, %rax              /* SYS_SRV_OPEN */
    syscall
    ret
    .size sys_srv_open, .-sys_srv_open


    /* --- syscall6(nr, a0, a1, a2, a3, a4, a5) -> int64 ---------------
     * Generic 6-arg syscall trampoline. SysV passes nr in %rdi, a0..a5
     * in %rsi/%rdx/%rcx/%r8/%r9/[stack]; the kernel syscall ABI wants
     * nr in %rax, a0..a5 in %rdi/%rsi/%rdx/%r10/%r8/%r9. We shuffle:
     *   * %rax <- %rdi (nr)
     *   * %rdi <- %rsi (a0)
     *   * %rsi <- %rdx (a1)
     *   * %rdx <- %rcx (a2)
     *   * %r10 <- %r8  (a3)
     *   * %r8  <- %r9  (a4)
     *   * %r9  <- 8(%rsp) (a5; stack arg)
     * %rcx is clobbered by SYSCALL (hardware writes user RIP there)
     * so we don't preserve it. Used by tests/test_p9file.ad to reach
     * SYS_CREATE/STAT/FSTAT/REMOVE/FD2PATH (260..264) without growing
     * a dedicated wrapper for each. */
    .globl syscall6
    .type syscall6, @function
syscall6:
    movq    %rdi, %rax              /* nr */
    movq    %rsi, %rdi              /* a0 */
    movq    %rdx, %rsi              /* a1 */
    movq    %rcx, %rdx              /* a2 */
    movq    %r8,  %r10              /* a3 (rcx -> r10 swap for syscall ABI) */
    movq    %r9,  %r8               /* a4 */
    movq    8(%rsp), %r9            /* a5 from stack */
    syscall
    ret
    .size syscall6, .-syscall6
