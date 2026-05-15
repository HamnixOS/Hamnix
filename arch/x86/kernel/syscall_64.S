/*
 * arch/x86/kernel/syscall_64.S - SYSCALL entry path + user-mode glue.
 *
 * Mirrors the role of arch/x86/entry/entry_64.S's `entry_SYSCALL_64`
 * at the smallest meaningful scale: a hand-off stub that
 *
 *   1. saves the user's RIP (came in via %rcx) and RFLAGS (via %r11),
 *   2. switches RSP from user_rsp to kernel_rsp,
 *   3. shuffles the syscall-ABI registers into SysV positions and
 *      calls a Pynux `do_syscall(nr, a0, a1, a2)`,
 *   4. restores everything and sysretq's back to user.
 *
 * Plus a few helpers Pynux needs that touch privileged MSRs / segment
 * selectors / iretq, neither expressible in pure Pynux today:
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
     */

    /* Park user RSP, load kernel RSP. user_rsp_save / kernel_rsp are
     * regular .data globals defined by Pynux side; leaq RIP-relative
     * because absolute references generate BFD_RELOC_X86_64_32S in
     * elf32-i386.   */
    leaq    user_rsp_save(%rip), %r12
    movq    %rsp, (%r12)
    leaq    kernel_rsp(%rip), %r12
    movq    (%r12), %rsp

    /* Save the SYSCALL hardware-saved regs for sysretq later. */
    pushq   %r11                      /* user RFLAGS */
    pushq   %rcx                      /* user RIP    */

    /* Shuffle user syscall ABI into SysV ABI for do_syscall:
     *   SysV rdi = nr   (was rax)
     *   SysV rsi = a0   (was rdi)
     *   SysV rdx = a1   (was rsi)
     *   SysV rcx = a2   (was rdx)   <- order matters: free %rcx first
     *   SysV r8  = a3   (was r10)
     */
    movq    %rdx, %rcx                /* a2 */
    movq    %rsi, %rdx                /* a1 */
    movq    %rdi, %rsi                /* a0 */
    movq    %rax, %rdi                /* nr */
    movq    %r10, %r8                 /* a3 */

    call    do_syscall                /* return value lands in %rax */

    /* Restore syscall-control regs and user RSP. */
    popq    %rcx                      /* user RIP    */
    popq    %r11                      /* user RFLAGS */
    leaq    user_rsp_save(%rip), %r12
    movq    (%r12), %rsp

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
 * to print "Pynux user: HELLO\n" character-by-character, then a
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
    /* Print "Pynux user: HELLO\n" — 18 bytes.  We unroll for clarity
     * over a string-loop (no .rodata trip needed). */
    movb    $'P',  %dil; movq $0, %rax; syscall
    movb    $'y',  %dil; movq $0, %rax; syscall
    movb    $'n',  %dil; movq $0, %rax; syscall
    movb    $'u',  %dil; movq $0, %rax; syscall
    movb    $'x',  %dil; movq $0, %rax; syscall
    movb    $' ',  %dil; movq $0, %rax; syscall
    movb    $'u',  %dil; movq $0, %rax; syscall
    movb    $'s',  %dil; movq $0, %rax; syscall
    movb    $'e',  %dil; movq $0, %rax; syscall
    movb    $'r',  %dil; movq $0, %rax; syscall
    movb    $':',  %dil; movq $0, %rax; syscall
    movb    $' ',  %dil; movq $0, %rax; syscall
    movb    $'H',  %dil; movq $0, %rax; syscall
    movb    $'E',  %dil; movq $0, %rax; syscall
    movb    $'L',  %dil; movq $0, %rax; syscall
    movb    $'L',  %dil; movq $0, %rax; syscall
    movb    $'O',  %dil; movq $0, %rax; syscall
    movb    $'\n', %dil; movq $0, %rax; syscall

    /* --- Spin loop: prove timer IRQs from CPL=3 work via TSS.RSP0 ---
     * 50M pause iterations at ~3 cycles each → ~150 ms wall time at
     * a typical QEMU virtual clock. At HZ=100 that's ~15 timer ticks
     * firing while we're at CPL 3. Without TSS those would fault.   */
    movq    $50000000, %rcx
.Luser_spin:
    pause
    decq    %rcx
    jnz     .Luser_spin

    /* Print 'X' to show the loop finished without crashing. */
    movb    $'X',  %dil; movq $0, %rax; syscall
    movb    $'\n', %dil; movq $0, %rax; syscall

    /* SYS_EXIT — kernel halts the box and reports jiffies; if it
     * advanced above 0, timer fired during the user-mode spin. */
    movq    $1, %rax
    syscall

.user_demo_hang:
    /* Defensive: shouldn't be reachable. We can't HLT in user mode
     * (#GP), so just spin. */
    jmp     .user_demo_hang
