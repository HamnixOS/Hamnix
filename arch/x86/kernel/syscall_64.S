/*
 * arch/x86/kernel/syscall_64.S - SYSCALL entry path + user-mode glue.
 *
 * Mirrors the role of arch/x86/entry/entry_64.S's `entry_SYSCALL_64`
 * at the smallest meaningful scale: a hand-off stub that
 *
 *   1. saves the user's RIP (came in via %rcx) and RFLAGS (via %r11),
 *   2. switches RSP from user_rsp to kernel_rsp,
 *   3. shuffles the syscall-ABI registers into SysV positions and
 *      calls a Hamnix `do_syscall(nr, a0, a1, a2)`,
 *   4. restores everything and sysretq's back to user.
 *
 * Plus a few helpers Hamnix needs that touch privileged MSRs / segment
 * selectors / iretq, neither expressible in pure Hamnix today:
 *
 *   write_msr / read_msr   - generic MSR access
 *   set_efer_sce            - flip IA32_EFER.SCE so SYSCALL works at all
 *   enter_user_mode         - iretq into ring-3 with a fabricated frame
 *   user_demo_entry         - tiny ring-3 program that exercises the
 *                              syscall path so the smoke test has
 *                              something to observe
 *
 * Single-CPU only. The user_rsp_save / kernel_rsp slots live in
 * regular .data globals (declared in arch/x86/kernel/syscall.py),
 * which is fine without SMP. When we go SMP these become Percpu[T]
 * and the stub does swapgs to reach them.
 */

    .code64
    .section .text, "ax"

/* ---------- syscall_entry: the SYSCALL handoff ------------------- */

    .align 16
    .globl syscall_entry
syscall_entry:
    /* On entry from SYSCALL:
     *   %rax = syscall number
     *   %rdi, %rsi, %rdx, %r10, %r8, %r9 = syscall args
     *   %rcx = saved user RIP
     *   %r11 = saved user RFLAGS
     *   CS / SS already loaded from STAR[47:32]
     *   IF cleared per IA32_FMASK
     *
     * Per SysV the user expects every callee-saved register
     * (%rbx, %rbp, %r12..%r15) intact across the syscall, plus the
     * caller-saved set that the syscall ABI doesn't carve out
     * (%rdi/%rsi/%rdx/%r10/%r8/%r9 are inputs but we shouldn't return
     * with them changed by the dispatch path).
     *
     * Per-task syscall stack (M16.35): we read the current task's
     * kernel stack from TSS.RSP0 (kept current by schedule()) and
     * stash the user RSP on THAT stack. Earlier revs spilled to a
     * single global (user_rsp_save / kernel_rsp) which broke as soon
     * as SYS_WAITPID started yielding mid-syscall — the child's own
     * later syscall_entry would overwrite the parent's saved slot.
     *
     * We use %r12 as a transient scratch — park user %r12 on the
     * user stack first so we can restore it on return.
     */
    pushq   %r12                      /* park user %r12 on user stack */

    /* %r12 = current task's kernel stack top (TSS.RSP0). schedule()
     * keeps tss64.rsp0 pointed at task->kstack_top on every switch. */
    leaq    tss64(%rip), %r12
    movq    4(%r12), %r12

    /* Park user RSP at kstack_top - 8, then switch to that slot.
     * After this, subsequent pushes land below the user-RSP slot,
     * and the matching popq %rsp at the tail restores it directly. */
    movq    %rsp, -8(%r12)            /* user rsp (with r12 push) -> kstack */
    leaq    -8(%r12), %rsp            /* RSP -> kernel stack just below it  */

    /* Save the SYSCALL hardware-saved regs for sysretq later. */
    pushq   %r11                      /* user RFLAGS */
    pushq   %rcx                      /* user RIP    */

    /* Shuffle user syscall ABI into SysV ABI for do_syscall. The user
     * register layout coming in:
     *   rax=nr  rdi=a0  rsi=a1  rdx=a2  r10=a3  r8=a4  r9=a5
     * SysV (callee) layout for do_syscall(nr, a0, a1, a2, a3, a4, a5):
     *   rdi=nr  rsi=a0  rdx=a1  rcx=a2  r8=a3  r9=a4  stack=a5
     *
     * U7: widened from 4 args (a0..a3) to 6 args (a0..a5) so the Linux
     * mmap (9) syscall — and any other 6-arg Linux syscall — can see
     * %r8 / %r9. The 7th arg (a5) is passed on the stack per SysV.
     *
     * Stack layout right before `call do_syscall`:
     *   kstack_top - 24 : already used (r11, rcx, r12-of-user via the
     *                     popq %rsp trick — see the parking dance above)
     *   kstack_top - 32 : alignment pad (must be at higher addr than a5)
     *   kstack_top - 40 : a5 (callee reads at 8(%rsp) after `call`
     *                     pushes the return address)
     *
     * Pre-call rsp = kstack_top - 40, which is 8 mod 16 (because
     * kstack_top is 16-aligned). After `call` pushes return: rsp =
     * -48, 16-aligned — SysV alignment satisfied. The two pushes get
     * undone after the call with `addq $16, %rsp`.
     */
    pushq   $0                        /* alignment pad (higher addr)  */
    pushq   %r9                       /* a5 -> stack arg 7            */

    /* Now do the register shuffle. Order matters: read each source
     * register before any move that would clobber it. r9 (target a4)
     * needs the old r8 (a4) BEFORE we trash r8 with r10 (a3). */
    movq    %r8,  %r9                 /* a4 (r9 = user r8)            */
    movq    %r10, %r8                 /* a3 (r8 = user r10)           */
    movq    %rdx, %rcx                /* a2                           */
    movq    %rsi, %rdx                /* a1                           */
    movq    %rdi, %rsi                /* a0                           */
    movq    %rax, %rdi                /* nr                           */

    call    do_syscall                /* return value lands in %rax */

    /* Reclaim the 16 bytes pushed for a5 + pad before unwinding the
     * rest of the kernel-side spill. */
    addq    $16, %rsp

    /* Restore syscall-control regs and user RSP. We pop the
     * (per-task) stored user RSP straight into %rsp; the next pop
     * pulls user %r12 from the user stack and sysretq returns. */
    popq    %rcx                      /* user RIP    */
    popq    %r11                      /* user RFLAGS */
    popq    %rsp                      /* user rsp    */
    popq    %r12                      /* user %r12   */

    sysretq                           /* CPL 0 -> 3, RIP=%rcx       */

/* ---------- write_msr(index, value) ------------------------------ */

    .align 16
    .globl write_msr
write_msr:
    movl    %edi, %ecx                /* MSR index from %edi (zero-ext) */
    movq    %rsi, %rax                /* low 32 from value             */
    movq    %rsi, %rdx
    shrq    $32, %rdx                 /* high 32                       */
    wrmsr
    ret

/* ---------- read_msr(index) -> uint64 --------------------------- */

    .align 16
    .globl read_msr
read_msr:
    movl    %edi, %ecx
    rdmsr
    shlq    $32, %rdx
    orq     %rdx, %rax
    ret

/* ---------- set_efer_sce: enable SYSCALL/SYSRET ------------------ */

    .align 16
    .globl set_efer_sce
set_efer_sce:
    movl    $0xC0000080, %ecx          /* IA32_EFER */
    rdmsr
    orl     $1, %eax                   /* bit 0 = SCE (Syscall Enable) */
    wrmsr
    ret

/* ---------- do_execve_finish(new_rip, new_rsp, argc, argv) -------- *
 * Tail-call from the SYS_EXECVE handler when it has loaded a new ELF
 * and wants to "become" that program. We never return through the
 * normal syscall path — instead we set up the registers SYSRETQ
 * reads (%rcx = new RIP, %r11 = new RFLAGS with IF=1) and load the
 * new user RSP directly, then SYSRETQ ourselves out to CPL=3.
 *
 * As of M16.35 the kernel also stages argc / argv for user _start by
 * delivering them in %rdi / %rsi. SysV makes those the first two
 * arguments to main(), so user code that declares
 *     def main(argc: int32, argv: Ptr[uint64]) -> int32:
 * receives them naturally; programs whose main() takes no args
 * (the existing hello.ad / init.S) simply don't read them.
 *
 * SysV inputs: %rdi=new_rip, %rsi=new_rsp, %rdx=argc, %rcx=argv.
 * No return.
 */

    .align 16
    .globl do_execve_finish
do_execve_finish:
    /* Stash argv in a scratch reg before we clobber %rcx with the
     * SYSRETQ RIP. After this we don't need any SysV-input regs
     * besides the ones being installed for user. */
    movq    %rcx, %r10                 /* save argv                   */
    movq    %rsi, %rsp                 /* user stack                  */
    movq    %rdi, %rcx                 /* SYSRETQ pulls RIP from %rcx */
    movq    %rdx, %rdi                 /* user %rdi = argc            */
    movq    %r10, %rsi                 /* user %rsi = argv            */
    movq    $0x202, %r11               /* RFLAGS (IF=1, reserved bit) */
    sysretq

/* ---------- enter_user_mode(entry, stack) ------------------------ *
 * Build an iretq frame on the kernel stack with CPL=3 selectors and
 * iretq into ring 3. The iret frame on x86_64 is always 5 quads in
 * long mode; we have to pop SS/RSP too because iretq with a CPL
 * change always pops them. RFLAGS = 0x002 = reserved bit only; IF=0
 * keeps preemption off in user mode (M16.17 doesn't yet handle a
 * timer IRQ landing on user context — that needs a TSS / RSP0 slot).
 *
 * SysV: %rdi = entry, %rsi = stack top
 */
    .align 16
    .globl enter_user_mode
enter_user_mode:
    /* Build a CPL-change iret frame:
     *   high: SS    (user data, RPL=3) = 0x18 | 3 = 0x1B
     *         RSP   (user stack top)
     *         RFLAGS (0x002 - IF clear)
     *         CS    (user code, RPL=3) = 0x20 | 3 = 0x23
     *   low:  RIP   (user entry)
     */
    pushq   $0x1B                      /* SS                          */
    pushq   %rsi                       /* RSP                         */
    pushq   $0x202                     /* RFLAGS (IF=1 - timer fires) */
    pushq   $0x23                      /* CS                          */
    pushq   %rdi                       /* RIP                         */
    iretq

/* ---------- user_demo_entry: ring-3 test payload ----------------- *
 * A tiny user program that issues a series of SYS_PUTC (nr=0) calls
 * to print "Hamnix user: HELLO\n" character-by-character, then a
 * SYS_EXIT (nr=1) which never returns. Demonstrates:
 *
 *   - User code actually executing at CPL 3 (the iretq landed).
 *   - SYSCALL transitions to CPL 0 with kernel CS/SS.
 *   - SYSRETQ returns to user, %rip = %rcx that the user provided.
 *   - The user can drive a loop and accumulate multiple syscalls.
 *
 * Each character is loaded into %rdi (syscall arg 0) and %rax holds
 * the syscall number. After SYS_EXIT we never return, but we still
 * emit a hang loop so a bug in the syscall path doesn't run off into
 * arbitrary memory. user-mode HLT is illegal (#GP), so the hang is
 * a plain `jmp .`.
 */
    .align 16
    .globl user_demo_entry
user_demo_entry:
    /* M16.26 demo: pre-opened stdout (fd 1) + stderr (fd 2) plus
     * SYS_WRITE to bulk-print; SYS_LSEEK to reposition; SYS_READ
     * still slurps the file. Exercises every fd-table-aware path
     * in fs/vfs.py end-to-end. */

    /* banner via stdout */
    movq    $1, %rdi
    leaq    user_banner(%rip), %rsi
    movq    $user_banner_end - user_banner, %rdx
    movq    $8, %rax                   /* SYS_WRITE                  */
    syscall

    /* fd = open("/motd") */
    leaq    fname_motd(%rip), %rdi
    movq    $5, %rax                   /* SYS_OPEN                   */
    syscall
    movq    %rax, %r13                 /* save fd                    */

    /* Stream the whole file: while ((n = read(fd, buf, 64)) > 0)
     *                              write(1, buf, n) */
.Lread_loop:
    movq    %r13, %rdi
    leaq    user_read_buf(%rip), %rsi
    movq    $64, %rdx
    movq    $6, %rax                   /* SYS_READ                   */
    syscall
    testq   %rax, %rax
    jle     .Lread_done

    movq    %rax, %rdx                 /* count = bytes read          */
    movq    $1, %rdi
    leaq    user_read_buf(%rip), %rsi
    movq    $8, %rax                   /* SYS_WRITE                  */
    syscall
    jmp     .Lread_loop

.Lread_done:
    /* lseek(fd, 9, SEEK_SET) + read 12 + write to stdout. Byte 9
     * of /motd is "Hamnix from a" — proves the seek repositions. */
    movq    %r13, %rdi
    movq    $9, %rsi
    movq    $0, %rdx                   /* SEEK_SET                   */
    movq    $9, %rax                   /* SYS_LSEEK                  */
    syscall

    /* "seeked: " label via stderr to mix the two streams */
    movq    $2, %rdi
    leaq    user_seek_label(%rip), %rsi
    movq    $user_seek_label_end - user_seek_label, %rdx
    movq    $8, %rax
    syscall

    movq    %r13, %rdi
    leaq    user_read_buf(%rip), %rsi
    movq    $12, %rdx
    movq    $6, %rax                   /* SYS_READ                   */
    syscall
    movq    %rax, %rdx
    movq    $1, %rdi
    leaq    user_read_buf(%rip), %rsi
    movq    $8, %rax                   /* SYS_WRITE                  */
    syscall

    /* End-of-output via stderr */
    movq    $2, %rdi
    leaq    user_eot(%rip), %rsi
    movq    $user_eot_end - user_eot, %rdx
    movq    $8, %rax
    syscall

    /* close + exit */
    movq    %r13, %rdi
    movq    $7, %rax                   /* SYS_CLOSE                  */
    syscall
    movq    $1, %rax                   /* SYS_EXIT                   */
    syscall

.user_demo_hang:
    jmp     .user_demo_hang

/* ---------- user-mode .data / .rodata ----------------------------
 * fname_motd is a string literal we point SYS_OPEN at. user_read_buf
 * is the 64-byte chunk SYS_READ fills.  Both pages are U=1 because
 * the entire identity-mapped region is.                              */
    .section .rodata
fname_motd:
    .asciz "/motd"
user_banner:
    .ascii "[user] M16.26 fd-table / write / lseek demo:\n"
user_banner_end:
user_seek_label:
    .ascii "\n[user] (stderr) after lseek(fd, 9, SEEK_SET): "
user_seek_label_end:
user_eot:
    .ascii "\n[user] (stderr) done.\n"
user_eot_end:

    .section .data
    .align 8
user_read_buf:
    .skip 64
