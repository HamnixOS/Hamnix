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
    /* TEMP_DEBUG_HAMSH_BRINGUP — real-hardware (Asus UEFI) bring-up.
     * Emit the earliest possible "I am alive in ring 3" marker BEFORE
     * touching any C-runtime state, BEFORE the argv shuffle into main.
     * If this line shows up on the framebuffer, the kernel's SYSRETQ
     * out of execve actually landed in user code AND userland writes
     * via sys_write(2, ...) reach the console — narrowing any silent
     * post-execve gap to "between _start and main()'s first print".
     *
     * Per-binary distinguisher: __runtime_start_mark and
     * __runtime_start_mark_end are .weak here with a fallback "unknown"
     * payload, and overridden per-binary by progname.o (generated and
     * linked by compiler/adder.py::assemble_and_link_x86_user). So
     * /init's _start prints "[runtime:init] _start" while hamsh's
     * _start prints "[runtime:hamsh] _start" — two distinct lines that
     * tell us whether SYSRETQ out of hamsh's execve actually landed in
     * hamsh's _start at all. If only "[runtime:init]" shows up on real
     * hardware, the kernel bug is between execve_finish and the first
     * user-mode instruction; if both show up, the wedge is later.
     *
     * Calling convention: %rdi = argc, %rsi = argv on entry from the
     * kernel. The syscall clobbers %rax / %rcx / %r11; we use %rdi /
     * %rsi / %rdx as direct syscall arg regs (so we must save and
     * restore the argc/argv pair across the call). Stack push/pop is
     * fine — the kernel handed us a 16-byte-aligned user stack with
     * usable room (see arch/x86/kernel/sched/core.ad).
     *
     * Remove together with the matching markers in user/hamsh.ad once
     * the silent-hamsh-on-real-hardware bug is debugged. */
    pushq   %rdi                            /* save argc */
    pushq   %rsi                            /* save argv */
    movq    $8, %rax                        /* SYS_WRITE */
    movq    $2, %rdi                        /* fd 2 = stderr -> framebuffer */
    leaq    __runtime_start_mark(%rip), %rsi
    movq    $__runtime_start_mark_end - __runtime_start_mark, %rdx
    syscall
    popq    %rsi                            /* restore argv */
    popq    %rdi                            /* restore argc */

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

    /* TEMP_DEBUG_HAMSH_BRINGUP — earliest-possible ring-3 marker
     * string. Sits in .rodata which init.lds merges into the single
     * PT_LOAD .text segment, so it loads alongside _start with no
     * extra program header. RIP-relative leaq above resolves with a
     * 32-bit displacement — fine within one PT_LOAD.
     *
     * Per-binary distinguisher: these symbols are .weak with a fallback
     * "unknown" payload below. Every Adder-compiled user binary's link
     * pulls in a tiny progname.o (synthesized by
     * compiler/adder.py::assemble_and_link_x86_user from the source's
     * basename) that supplies STRONG definitions of the same two
     * symbols, with a `[runtime:<name>] _start\n` payload. The linker
     * prefers the strong definitions, so each binary ships its own
     * marker text. The hand-written .S binaries (hello, stdin_demo)
     * don't go through assemble_and_link_x86_user and thus fall back
     * to the weak "[runtime:unknown] _start" — that's fine, they're
     * not part of the init/hamsh bring-up path.
     */
    .section .rodata
    .align 8
    .weak __runtime_start_mark
    .weak __runtime_start_mark_end
__runtime_start_mark:
    .ascii "[runtime:unknown] _start\n"
__runtime_start_mark_end:

    .section .text, "ax"

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


    /* --- sys_read_nb(fd, buf, count) -> int64 -----------------------
     * Non-blocking read. Returns >0 bytes ready now, 0 if the fd is
     * open but momentarily empty ("would block"), or -1 on a true EOF
     * / error. Lets a single-threaded event-loop daemon (user/sshd.ad)
     * poll a socket fd and a pipe fd in one task without either read
     * wedging it. */
    .globl sys_read_nb
    .type sys_read_nb, @function
sys_read_nb:
    movq    $23, %rax               /* SYS_READ_NB */
    syscall
    ret
    .size sys_read_nb, .-sys_read_nb


    /* --- sys_yield() -> int32 ---------------------------------------
     * Cooperative yield: drop the CPU to any other ready task. Hamnix
     * multitasks cooperatively (no working timer preemption), so a
     * single-threaded non-blocking event-loop daemon MUST call this on
     * every idle poll iteration or it starves every other task. Always
     * returns 0. */
    .globl sys_yield
    .type sys_yield, @function
sys_yield:
    movq    $24, %rax               /* SYS_YIELD */
    syscall
    ret
    .size sys_yield, .-sys_yield


    /* --- sys_nice(nice, op) -> int64 --------------------------------
     * #151 / CFS-lite. op==0 SET the calling task's nice (arg0, clamped
     * to [-20,+19]); op==1 GET (arg0 ignored). Returns the resulting
     * nice value. SysV arg regs rdi/rsi already align with the syscall
     * arg regs, so no shuffle is needed. */
    .globl sys_nice
    .type sys_nice, @function
sys_nice:
    movq    $311, %rax              /* SYS_NICE */
    syscall
    ret
    .size sys_nice, .-sys_nice


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


    /* --- sys_execve_env(path, argv, envp) — never returns on success -
     * 3-arg form of execve: a0=path (%rdi), a1=argv (%rsi), a2=envp
     * (%rdx). SysV already places these in exactly the syscall ABI's
     * a0/a1/a2 registers, so no shuffle is needed. envp is a
     * NULL-terminated Ptr[uint64] array of "NAME=VALUE\0" cstrings (or
     * 0 for empty env). login/su use this to stamp HAMNIX_NEWSHELL_USER
     * so the exec'd /bin/hamsh sources the per-user namespace recipe. */
    .globl sys_execve_env
    .type sys_execve_env, @function
sys_execve_env:
    movq    $10, %rax               /* SYS_EXECVE */
    syscall
    ret                             /* only reached on failure */
    .size sys_execve_env, .-sys_execve_env


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


    /* --- sys_waitpid(pid) -> int64 (child exit_code or -errno) ------
     * Single-arg, BLOCKING wait. SYS_WAITPID reads a1 (%rsi) as a flags
     * word whose bit 0 is WNOHANG. This wrapper takes ONE C argument
     * (pid, in %edi), so %rsi is whatever the caller happened to leave
     * there — it is NOT a syscall argument. We MUST zero it, or a stale
     * %rsi with bit 0 set silently turns this blocking wait into a
     * WNOHANG poll: the kernel returns -EAGAIN without reaping, the
     * caller treats that as the child's status, and the EXITED child is
     * never reaped — leaking a task slot per such call until the table
     * fills and every further sys_spawn fails ("command not found").
     * Zeroing %rsi pins the documented "a1=0 -> blocking" contract. */
    .globl sys_waitpid
    .type sys_waitpid, @function
sys_waitpid:
    xorl    %esi, %esi              /* a1 = flags = 0 (BLOCKING, no WNOHANG) */
    movq    $12, %rax               /* SYS_WAITPID */
    syscall
    ret
    .size sys_waitpid, .-sys_waitpid


    /* --- sys_waitpid_nb_raw(pid, flags) -> int64 ---------------------
     * Flagged variant of SYS_WAITPID. Same syscall number (12); the
     * kernel reads a1 = flags and honours bit 0 (WNOHANG) by returning
     * -EAGAIN (-11) instead of looping in yield_to_others. Used by
     * the init-side service supervisor to reap supervised children
     * without blocking PID 1's interactive prompt.
     *
     * Arg layout per System-V x86_64: pid in %edi, flags in %rsi —
     * already the right registers for SYSCALL's (a0,a1) ABI, no
     * rearrangement needed. */
    .globl sys_waitpid_nb_raw
    .type sys_waitpid_nb_raw, @function
sys_waitpid_nb_raw:
    movq    $12, %rax               /* SYS_WAITPID */
    syscall
    ret
    .size sys_waitpid_nb_raw, .-sys_waitpid_nb_raw


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


    /* --- RETIRED: sys_socket / sys_connect / sys_tls_connect --------
     * --- and sys_sock_bind / sys_listen / sys_accept ----------------
     * ARCH §10: ALL native BSD socket syscalls are RETIRED. Hamnix
     * Layer 1 is Plan-9-shaped — networking is the /net file tree, NOT
     * a socket() syscall family:
     *   SYS_SOCKET (41), SYS_CONNECT (42)        — active open
     *   SYS_ACCEPT_SOCK (43)                     — passive accept
     *   SYS_BIND_SOCK (49), SYS_LISTEN_SOCK (50) — passive open
     *   SYS_TLS_CONNECT                          — TLS handshake
     * Native Adder binaries dial / announce / accept / TLS-upgrade by
     * open/read/write on /net/tcp via user/net9.ad — net_dial /
     * net_dial_tls / net_announce / net_accept (built on sys_open /
     * sys_read / sys_write). A TLS connection is dialed by net_dial_tls,
     * which writes a `connect` then a `tls <host>` ctl command; the
     * latter runs the in-kernel TLS 1.3 handshake over the connection.
     * The wrapper stubs that issued those syscall numbers are gone
     * with them; the numbers are unassigned in the native dispatch
     * table (arch/x86/kernel/syscall.ad). */


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


    /* --- sys_resolve_ptr(ip, buf, cap) -> int64 ---------------------
     * U-resolve-reverse: native-ABI IPv4 -> hostname. Hands the target
     * IPv4 packed big-endian in the low 32 bits of %rdi (octet 0 in
     * bits 31:24, the same packing sys_resolve returns), an out buffer
     * (%rsi) and its capacity (%rdx) to the in-kernel reverse resolver
     * via SYS_RESOLVE_PTR (301) -> dns_lookup_ptr. On success %rax is 0
     * and the NUL-terminated PTR name is written into the buffer; on
     * failure %rax is a negative errno (-2 == cannot resolve). Three
     * args fit the SysV/syscall-ABI overlap directly — no shuffle. */
    .globl sys_resolve_ptr
    .type sys_resolve_ptr, @function
sys_resolve_ptr:
    movq    $301, %rax              /* SYS_RESOLVE_PTR */
    syscall
    ret
    .size sys_resolve_ptr, .-sys_resolve_ptr


    /* --- RETIRED: sys_tls_connect -----------------------------------
     * ARCH §10: SYS_TLS_CONNECT is RETIRED with the rest of the BSD
     * socket syscalls — see the retirement note above sys_resolve.
     * Native code does TLS the Plan 9 way: net_dial_tls (user/net9.ad)
     * writes a `tls <host>` ctl command to a connected /net/tcp conn,
     * which runs the in-kernel TLS 1.3 handshake over the connection.
     * Syscall number 277 is unassigned in the dispatch table. */


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


    /* --- sys_setpgid(pid, pgid) -> int32 -----------------------------
     * Job control: place `pid` (0 = self) in process group `pgid`
     * (0 = use pid). pid in %edi, pgid in %esi — already the right
     * (a0,a1) registers, no shuffle. Returns 0 or -ESRCH. */
    .globl sys_setpgid
    .type sys_setpgid, @function
sys_setpgid:
    movq    $297, %rax              /* SYS_SETPGID */
    syscall
    ret
    .size sys_setpgid, .-sys_setpgid


    /* --- sys_tcsetpgrp(pgid) -> int32 --------------------------------
     * Job control: make `pgid` the terminal's foreground process
     * group, so Ctrl-C/Ctrl-Z route only there. pgid in %edi = a0.
     * Always returns 0. */
    .globl sys_tcsetpgrp
    .type sys_tcsetpgrp, @function
sys_tcsetpgrp:
    movq    $298, %rax              /* SYS_TCSETPGRP */
    syscall
    ret
    .size sys_tcsetpgrp, .-sys_tcsetpgrp


    /* --- sys_waitpid_jc(pid, status) -> int64 ------------------------
     * Job control: non-blocking wait reporting EXITED / STOPPED /
     * CONTINUED. pid in %edi = a0, &status (int64*) in %rsi = a1 —
     * already the right registers. Returns the pid (>0) when there is
     * something to report, 0 when nothing new, -ECHILD on bad pid. */
    .globl sys_waitpid_jc
    .type sys_waitpid_jc, @function
sys_waitpid_jc:
    movq    $299, %rax              /* SYS_WAITPID_JC */
    syscall
    ret
    .size sys_waitpid_jc, .-sys_waitpid_jc


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


    /* --- sys_fdbind(pid, fdnum, kind, arg) -> int32 -----------------
     * HAMSH §7: bind a Chan at an /fd/N name. THE one primitive —
     * pipe, redirect, AND dup all reduce to it. `pid` (0 = the
     * caller's own Pgrp) selects whose namespace; `fdnum` is the
     * destination /fd slot; `kind` is a DEVFD_* channel kind; `arg`
     * is kind-dependent:
     *   DEVFD_CONS   — arg ignored.
     *   DEVFD_PIPE_R/W — arg is the pipe slot.
     *   DEVFD_FILE   — arg is the kernel fd of the opened file.
     *   DEVFD_DUP    — arg is a SOURCE /fd slot: `cmd 2>&1` is
     *                  sys_fdbind(pid, 2, DEVFD_DUP, 1), i.e. bind
     *                  /fd/1's existing Chan also at the name /fd/2.
     * There is no separate dup syscall — dup is just a bind whose
     * source Chan is taken from an existing /fd/N slot.
     * SysV's first four arg regs (%rdi/%rsi/%rdx/%rcx) — %rcx must
     * move to %r10 for the syscall ABI. Returns 0 / -1 + errstr. */
    .globl sys_fdbind
    .type sys_fdbind, @function
sys_fdbind:
    movq    %rcx, %r10              /* arg 4: arg -> r10 for syscall ABI */
    movq    $278, %rax              /* SYS_FDBIND */
    syscall
    ret
    .size sys_fdbind, .-sys_fdbind


    /* --- sys_fdslot_kind(pid, fdnum) -> int32 -----------------------
     * HAMSH §7: read-only query for the DEVFD_* kind currently bound at
     * /fd/<fdnum> in pid's Pgrp (pid 0 = self). Returns DEVFD_NONE (0)
     * for unbound slot, bad pid, or out-of-range fdnum. hamsh uses this
     * before its default cons-bind so it can detect that the kernel-
     * side legacy-fd SYS_SPAWN path has already pre-baked /fd/0,1,2 to
     * pipe ends (the sshd → hamsh case) and leave them alone. */
    .globl sys_fdslot_kind
    .type sys_fdslot_kind, @function
sys_fdslot_kind:
    movq    $287, %rax              /* SYS_FDSLOT_KIND */
    syscall
    ret
    .size sys_fdslot_kind, .-sys_fdslot_kind


    /* --- sys_getuid() -> uint32 --------------------------------------
     * docs/security.md: Plan-9-shape uid. Returns the current task's
     * uid widened to a 64-bit return (always fits in uint32). */
    .globl sys_getuid
    .type sys_getuid, @function
sys_getuid:
    movq    $288, %rax              /* SYS_GETUID */
    syscall
    ret
    .size sys_getuid, .-sys_getuid


    /* --- sys_getgid() -> uint32 -------------------------------------- */
    .globl sys_getgid
    .type sys_getgid, @function
sys_getgid:
    movq    $289, %rax              /* SYS_GETGID */
    syscall
    ret
    .size sys_getgid, .-sys_getgid


    /* --- sys_setuid(uid) -> int32 ------------------------------------
     * Privileged: only the hostowner (uid 1) can call. The kernel
     * gates with -EPERM otherwise. The only legitimate userland caller
     * is hamsh's `newshell` builtin after authenticating against
     * /etc/shadow. */
    .globl sys_setuid
    .type sys_setuid, @function
sys_setuid:
    movq    $290, %rax              /* SYS_SETUID */
    syscall
    ret
    .size sys_setuid, .-sys_setuid


    /* --- sys_svc_publish(name, payload) -> int32 --------------------
     * /proc/svc Phase 6: ship one service-registry slot into the
     * kernel-side mirror in fs/procfs.ad. name = NUL-terminated
     * service name, payload = 400-byte packed struct (or NULL/0 to
     * unpublish). Hostowner-only at the kernel side; hamsh IS PID 1
     * so the gate never bites the legitimate path. */
    .globl sys_svc_publish
    .type sys_svc_publish, @function
sys_svc_publish:
    movq    $291, %rax              /* SYS_SVC_PUBLISH */
    syscall
    ret
    .size sys_svc_publish, .-sys_svc_publish


    /* --- sys_svc_ctl(verb, name, cap) -> int64 ----------------------
     * Service-control mailbox RPC to PID-1's supervisor. verb 1..6 =
     * start/stop/restart/enable/disable/runlevel (name = service or
     * runlevel digit) — enqueue, returns 0. verb 0 = poll (PID-1 only):
     * dequeue the next request, returns the request's verb (0 = queue
     * empty). verb 7 = read out the last-dequeued name into the buffer
     * at `name` (cap bytes). The native `service` / `init` commands use
     * verbs 1..6; hamsh's supervisor uses 0 + 7. */
    .globl sys_svc_ctl
    .type sys_svc_ctl, @function
sys_svc_ctl:
    movq    $296, %rax              /* SYS_SVC_CTL */
    syscall
    ret
    .size sys_svc_ctl, .-sys_svc_ctl


    /* --- sys_set_realtime(epoch) -> int32 ---------------------------
     * Anchor the kernel-side wall clock on `epoch` (Unix seconds).
     * The kernel re-bases rtc_boot_epoch so that base + TSC-delta ==
     * epoch from this instant forward. user/ntpd.ad calls this after
     * parsing an NTP response. Hostowner-only; ntpd runs from
     * /etc/rc.boot which is PID 1's interpreter — the gate never
     * bites the legitimate boot path. Returns 0 on success or -1 with
     * errstr set ("set_realtime: bad epoch" / "permission denied"). */
    .globl sys_set_realtime
    .type sys_set_realtime, @function
sys_set_realtime:
    movq    $292, %rax              /* SYS_SET_REALTIME */
    syscall
    ret
    .size sys_set_realtime, .-sys_set_realtime


    /* --- sys_wsys_alloc(pid) -> int32 -------------------------------
     * hamUI Phase 2: register a child task's pid against a wid slot
     * (2..MAX_WINDOWS-1) in the kernel's wsys table. Returns the
     * assigned wid on success or -1 if the table is full / pid is
     * already bound. Hostowner-only on the kernel side. The /bin/hamUI
     * tool calls this after sys_spawn'ing a detached hamsh — the wid
     * is the addressing key for /dev/wsys/<wid>/* from any namespace.
     * Number 293 (not 292) because F2's SYS_SET_REALTIME took 292. */
    .globl sys_wsys_alloc
    .type sys_wsys_alloc, @function
sys_wsys_alloc:
    movq    $293, %rax              /* SYS_WSYS_ALLOC */
    syscall
    ret
    .size sys_wsys_alloc, .-sys_wsys_alloc


    /* --- sys_wsys_free(wid) -> int32 --------------------------------
     * hamUI Phase 2: release a wid slot. Caller is responsible for
     * SIGTERM'ing the bound shell first; this just clears the table
     * entry. Returns 0 on success, -1 on bad wid (or wid==1, which is
     * the foreground console and is unfreeable). Number 294 because
     * F2's SYS_SET_REALTIME took 292 and SYS_WSYS_ALLOC is 293. */
    .globl sys_wsys_free
    .type sys_wsys_free, @function
sys_wsys_free:
    movq    $294, %rax              /* SYS_WSYS_FREE */
    syscall
    ret
    .size sys_wsys_free, .-sys_wsys_free


    /* --- sys_pipechan() -> int32 ------------------------------------
     * HAMSH §7: create a local pipe Chan pair; returns the pipe SLOT
     * id (NOT fds). The shell threads the slot into two sys_fdbind
     * calls — write end at the producer's /fd/1, read end at the
     * consumer's /fd/0. A local pipe never speaks 9P. Returns the
     * slot id (>= 0) or -1 with errstr set. */
    .globl sys_pipechan
    .type sys_pipechan, @function
sys_pipechan:
    movq    $280, %rax              /* SYS_PIPECHAN */
    syscall
    ret
    .size sys_pipechan, .-sys_pipechan


    /* --- sys_openchan(path, write) -> int32 -------------------------
     * HAMSH §7: open an on-disk file as a namespace-shareable channel
     * for a `cmd > file` / `cmd < file` redirect. `write` = 0 looks
     * up an existing file, 1 creates+truncates. Returns the tmpfs
     * slot id (>= 0) — which the shell binds at a child's /fd/N via
     * sys_fdbind(child, N, DEVFD_FILE, slot) — or -1 + errstr. */
    .globl sys_openchan
    .type sys_openchan, @function
sys_openchan:
    movq    $281, %rax              /* SYS_OPENCHAN */
    syscall
    ret
    .size sys_openchan, .-sys_openchan


    /* --- sys_nsid() -> uint64 ---------------------------------------
     * HAMSH §13: an opaque, stable per-Pgrp namespace identity (the
     * calling task's Pgrp pointer). Every `ns {}` / `enter` / `spawn`
     * rforks a fresh Pgrp, hence a fresh nsid. A live handle records
     * the nsid it was created under; using it where sys_nsid() now
     * differs is the cross-namespace-handle error. */
    .globl sys_nsid
    .type sys_nsid, @function
sys_nsid:
    movq    $282, %rax              /* SYS_NSID */
    syscall
    ret
    .size sys_nsid, .-sys_nsid


    /* --- sys_nslabel(op, label, to_path, from_path) -> int32 --------
     * HAMSH §14: mount handles. op=0 stamps `label` onto the mount
     * at `to_path` (and `from_path` for a bind); op=1 unmounts the
     * single entry carrying `label`. A label is a unique handle, so
     * it names a union branch in /proc/self/ns and lets `unmount`
     * peel exactly one branch. 4-arg syscall — %rcx (arg 4) must
     * move to %r10 for the syscall ABI. Returns 0 / -1 + errstr. */
    .globl sys_nslabel
    .type sys_nslabel, @function
sys_nslabel:
    movq    %rcx, %r10              /* arg 4: from_path -> r10 */
    movq    $285, %rax              /* SYS_NSLABEL */
    syscall
    ret
    .size sys_nslabel, .-sys_nslabel


    /* --- sys_netcfg(op, a1, a2) -> int64 ----------------------------
     * Network info + static configuration. The `ifconfig` command
     * reads and writes the IPv4 stack's address / netmask / gateway /
     * DNS through this one multiplexed syscall (SYS_NETCFG = 286 ->
     * do_netcfg).
     *   op 0 GET:      a1 = Ptr to a 24-byte buffer; kernel fills it.
     *   op 1 SET_ADDR: a1 = address packed (octet0<<24..octet3),
     *                  a2 = netmask packed the same way.
     *   op 2 SET_GW:   a1 = gateway packed.
     *   op 3 SET_DNS:  a1 = DNS server packed.
     * Three args fit the SysV/syscall-ABI overlap directly (rdi/rsi/
     * rdx) — no shuffle. Returns 0 on success, -1 + errstr on a bad
     * op / null buffer. */
    .globl sys_netcfg
    .type sys_netcfg, @function
sys_netcfg:
    movq    $286, %rax              /* SYS_NETCFG */
    syscall
    ret
    .size sys_netcfg, .-sys_netcfg


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


    /* --- sys_rfork_thread(flags, child_stack, tls) -> int32 ---------
     * §1: the RFMEM (POSIX-thread) form of rfork. Creates a child that
     * SHARES the caller's address space and runs on `child_stack` with
     * `tls` as its %fs base (0 = inherit). The caller MUST set RFMEM in
     * `flags`; without it the kernel takes the plain fork path and the
     * extra args are ignored.
     *
     * SysV passes flags in %rdi (a0), child_stack in %rsi (a1), tls in
     * %rdx (a2) — all three align with the syscall ABI's a0/a1/a2, no
     * shuffle needed. %r9 (a5) carries the caller's %rbp exactly like
     * sys_rfork: do_rfork patches the child's initial-stack frame
     * pointer (the fork path uses it; the thread path ignores it since
     * the child runs on its own stack). Returns child pid in the
     * creator, 0 in the new thread, -EINVAL/-EAGAIN on error. */
    .globl sys_rfork_thread
    .type sys_rfork_thread, @function
sys_rfork_thread:
    movq    %rbp, %r9               /* a5 = creator user %rbp */
    movq    $256, %rax              /* SYS_RFORK */
    syscall
    ret
    .size sys_rfork_thread, .-sys_rfork_thread


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


    /* --- sys_dfs_load(inst, buf, max_len) -> int64 ------------------
     * distrofs persistent backing: load distrofs instance `inst`'s
     * RAM-table snapshot from the ext4 volume into `buf` (up to
     * `max_len` bytes). Returns bytes read, 0 if no snapshot exists
     * yet, -1 if no ext4 volume is mounted / on I/O error. distrofs
     * (user/distrofs.ad) calls this once at startup so an installed
     * package survives a reboot. The backing-file name is kernel-
     * owned — only the small instance id (0..15) is passed, never a
     * path (namespace law: the ext4 image is distrofs's private
     * backing store, not a globally-mounted route). Three args fit
     * the SysV/syscall-ABI overlap directly — no register shuffle. */
    .globl sys_dfs_load
    .type sys_dfs_load, @function
sys_dfs_load:
    movq    $283, %rax              /* SYS_DFS_LOAD */
    syscall
    ret
    .size sys_dfs_load, .-sys_dfs_load


    /* --- sys_dfs_save(inst, buf, length) -> int64 -------------------
     * distrofs persistent backing: persist `length` bytes from `buf`
     * as distrofs instance `inst`'s RAM-table snapshot on the ext4
     * volume, fsync'd. Returns bytes written, -1 on failure. distrofs
     * calls this when a write-mode fid is clunked and at clean
     * shutdown, so the durable STATE tracks the ephemeral namespace
     * VIEW. Three args fit the SysV/syscall-ABI overlap directly —
     * no register shuffle. */
    .globl sys_dfs_save
    .type sys_dfs_save, @function
sys_dfs_save:
    movq    $284, %rax              /* SYS_DFS_SAVE */
    syscall
    ret
    .size sys_dfs_save, .-sys_dfs_save


    /* --- sys_useradd_root(name) -> int32 ----------------------------
     * docs/security.md multi-user landing: create a per-user home FILE
     * SERVER on the shared ext4 root. name = NUL-terminated username.
     * The kernel appends a `<name> <name>` line to `.hamnix-roots`,
     * mkdir's the top-level `<name>/` subtree, and name_push()es the
     * `#<name>` root LIVE (so the user can log in this boot; the
     * sentinel line makes it survive a reboot). Hostowner-only at the
     * kernel side. Returns 0 on success or a negative errno
     * (-EROFS/-EINVAL/-EEXIST/-ENOSPC/-EPERM). Number 295. */
    .globl sys_useradd_root
    .type sys_useradd_root, @function
sys_useradd_root:
    movq    $295, %rax              /* SYS_USERADD_ROOT */
    syscall
    ret
    .size sys_useradd_root, .-sys_useradd_root


    /* --- sys_setuid_auth(auth_fd) -> int32 --------------------------
     * docs/security.md Phase 4: /dev/auth-mediated identity change.
     * auth_fd = an open /dev/auth fd that has SUCCESSFULLY verified a
     * (user, pass) pair. The kernel recovers the fd's devauth slot,
     * confirms it verified, and sets the calling task's uid+gid to the
     * slot's verified pair. Returns the new uid on success, -1 if the
     * fd isn't an /dev/auth fd or hasn't authenticated. This is the
     * honest "prove the password, the kernel changes you" primitive
     * login/su use to drop a fresh process into the authenticated
     * identity even from a non-hostowner context. Number 300. */
    .globl sys_setuid_auth
    .type sys_setuid_auth, @function
sys_setuid_auth:
    movq    $300, %rax              /* SYS_SETUID_AUTH */
    syscall
    ret
    .size sys_setuid_auth, .-sys_setuid_auth


    /* --- sys_mmap(addr, len, prot, flags, fd, offset) -> int64 --------
     * §142: native mmap syscall (SYS_MMAP = 302). 6-arg call — the
     * SysV ABI passes arg 4 (flags) in %rcx and arg 5 (fd) in %r8,
     * arg 6 (offset) on the stack. The syscall ABI reserves %rcx for
     * the user RIP and uses %r10 for arg 4; arg 5 (%r8) and arg 6
     * (%r9) align between the two ABIs when the caller shuffles arg 6
     * from the stack into %r9. Same pattern as the generic syscall6
     * trampoline below but specialised for mmap to document the arg map.
     *
     * System V argument registers for sys_mmap:
     *   %rdi = addr (a0)       → stays %rdi
     *   %rsi = len  (a1)       → stays %rsi
     *   %rdx = prot (a2)       → stays %rdx
     *   %rcx = flags (a3)      → %r10 (syscall ABI a3)
     *   %r8  = fd    (a4)      → stays %r8
     *   8(%rsp) = offset (a5)  → %r9  (syscall ABI a5)
     *   %rax = 302 (SYS_MMAP)
     *
     * Returns the mapped address (positive) or a negative errno.
     */
    .globl sys_mmap
    .type sys_mmap, @function
sys_mmap:
    movq    %rcx, %r10              /* flags (a3): rcx -> r10 */
    movq    8(%rsp), %r9            /* offset (a5): stack -> r9 */
    movq    $302, %rax              /* SYS_MMAP */
    syscall
    ret
    .size sys_mmap, .-sys_mmap


    /* --- sys_mprotect(addr, len, prot) -> int32 -----------------------
     * §142: native mprotect syscall (SYS_MPROTECT = 303). 3-arg call;
     * SysV registers align directly with syscall ABI a0..a2 — no
     * shuffle. Returns 0 on success or a negative errno. */
    .globl sys_mprotect
    .type sys_mprotect, @function
sys_mprotect:
    movq    $303, %rax              /* SYS_MPROTECT */
    syscall
    ret
    .size sys_mprotect, .-sys_mprotect


    /* --- sys_munmap(addr, len) -> int32 --------------------------------
     * §142: native munmap syscall (SYS_MUNMAP = 304). 2-arg call;
     * SysV registers align directly with syscall ABI a0..a1 — no
     * shuffle. Returns 0 on success or a negative errno. */
    .globl sys_munmap
    .type sys_munmap, @function
sys_munmap:
    movq    $304, %rax              /* SYS_MUNMAP */
    syscall
    ret
    .size sys_munmap, .-sys_munmap


    /* --- sys_symlink(target, linkpath) -> int32 -----------------------
     * M16.x §links: create a symbolic link at `linkpath` whose content
     * is `target` (SYS_SYMLINK = 305). 2-arg call; SysV a0=target in
     * %rdi, a1=linkpath in %rsi — both align directly with the syscall
     * ABI, so no shuffle needed. Returns 0 on success or -errno. */
    .globl sys_symlink
    .type sys_symlink, @function
sys_symlink:
    movq    $305, %rax              /* SYS_SYMLINK */
    syscall
    ret
    .size sys_symlink, .-sys_symlink


    /* --- sys_link(oldpath, newpath) -> int32 --------------------------
     * M16.x §links: create a hard link (SYS_LINK = 306). 2-arg call;
     * SysV a0=oldpath in %rdi, a1=newpath in %rsi. Returns 0 on success,
     * -EXDEV (-18) when oldpath and newpath are on different file servers
     * (Plan 9 / namespace boundary rejection), or other -errno. */
    .globl sys_link
    .type sys_link, @function
sys_link:
    movq    $306, %rax              /* SYS_LINK */
    syscall
    ret
    .size sys_link, .-sys_link


    /* --- sys_clock_gettime(clockid, tp) -> int64 ----------------------
     * §146: native clock_gettime syscall (SYS_CLOCK_GETTIME = 307).
     * Renumbered from 305 — VFS §links owns 305/306.
     * clockid in %edi (a0), struct timespec* in %rsi (a1).
     * SysV registers align with syscall ABI a0..a1 — no shuffle. */
    .globl sys_clock_gettime
    .type sys_clock_gettime, @function
sys_clock_gettime:
    movq    $307, %rax              /* SYS_CLOCK_GETTIME */
    syscall
    ret
    .size sys_clock_gettime, .-sys_clock_gettime


    /* --- sys_nanosleep(req, rem) -> int64 -----------------------------
     * §146: native nanosleep syscall (SYS_NANOSLEEP = 308).
     * Renumbered from 306 — VFS §links owns 305/306.
     * req (struct timespec*) in %rdi (a0), rem (struct timespec*) in
     * %rsi (a1). SysV registers align directly — no shuffle. */
    .globl sys_nanosleep
    .type sys_nanosleep, @function
sys_nanosleep:
    movq    $308, %rax              /* SYS_NANOSLEEP */
    syscall
    ret
    .size sys_nanosleep, .-sys_nanosleep


    /* --- sys_timerfd_create(clockid, flags) -> int64 ------------------
     * §146: native timerfd_create syscall (SYS_TIMERFD_CREATE = 309).
     * clockid in %edi (a0), flags in %esi (a1). Returns fd or -errno. */
    .globl sys_timerfd_create
    .type sys_timerfd_create, @function
sys_timerfd_create:
    movq    $309, %rax              /* SYS_TIMERFD_CREATE */
    syscall
    ret
    .size sys_timerfd_create, .-sys_timerfd_create


    /* --- sys_timerfd_settime(fd, flags, new, old) -> int64 ------------
     * §146: native timerfd_settime syscall (SYS_TIMERFD_SETTIME = 310).
     * fd in %edi (a0), flags in %esi (a1), new in %rdx (a2), old in
     * %rcx (a3) — %rcx must move to %r10 for syscall ABI. */
    .globl sys_timerfd_settime
    .type sys_timerfd_settime, @function
sys_timerfd_settime:
    movq    %rcx, %r10              /* old (a3): rcx -> r10 */
    movq    $310, %rax              /* SYS_TIMERFD_SETTIME */
    syscall
    ret
    .size sys_timerfd_settime, .-sys_timerfd_settime


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
