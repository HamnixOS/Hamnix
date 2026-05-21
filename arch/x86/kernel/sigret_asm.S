/*
 * arch/x86/kernel/sigret_asm.S - §3 user-mode signal trampoline.
 *
 * Runs at CPL=3. Hamnix's 1 GiB identity map carries US=1 on every
 * PDPT entry (arch/x86/boot/header.S), so kernel .text is directly
 * executable from user mode — that lets us host the trampoline in
 * the kernel image without round-tripping through a per-task mmap'd
 * page. When per-task private user mappings land (post-U-track), we
 * relocate this stub into a vDSO-style page.
 *
 * Contract with deliver_signal_to_user() in kernel/sched/core.ad:
 *
 *   At trampoline entry the user stack holds a 4-quad "pop area"
 *   built by deliver_signal_to_user, with the full siginfo_t and
 *   ucontext_t carved just above it:
 *
 *       (low)  RSP -> signo        <- arg 1, popped into %rdi
 *              RSP+8  -> info_ptr  <- arg 2, popped into %rsi
 *              RSP+16 -> uc_ptr    <- arg 3, popped into %rdx
 *              RSP+24 -> handler   <- call target, popped into %rax
 *       (high) siginfo_t / ucontext_t (read by an SA_SIGINFO handler
 *                                      and by rt_sigreturn)
 *
 *   syscall_64.S parks user RSP at (natural_user_rsp - 8) on entry —
 *   the pushq %r12 of the entry stub consumed those 8 bytes — and the
 *   matching popq %r12 at exit lifts RSP back up by 8 before SYSRETQ
 *   resumes user mode. deliver_signal_to_user accounts for that by
 *   writing rsp_slot[0] = pop_top - 8: the final popq %r12 reads the
 *   8 bytes BELOW the pop area (the value loaded into user %r12 is
 *   irrelevant — a SysV handler saves %r12 itself) and RSP ends up at
 *   pop_top with `signo` at the top of the stack.
 *
 *   On entry:
 *     %rdi..%r11: per the SYSRETQ contract — caller-saved, may carry
 *                stale syscall-return scratch values. The four pops
 *                below overwrite %rdi/%rsi/%rdx/%rax with our frame
 *                values before the handler runs.
 *     RFLAGS: 0x202 (IF=1, reserved bit), forced by SYSRETQ
 *
 *   The trampoline:
 *     1. pops signo / info_ptr / uc_ptr / handler into
 *        %rdi / %rsi / %rdx / %rax — the SysV 3-arg handler ABI
 *          void handler(int signo, siginfo_t *info, void *ucontext)
 *        A non-SA_SIGINFO handler `void handler(int)` simply ignores
 *        %rsi/%rdx — the 1-arg form is a strict prefix of the 3-arg.
 *     3. calls *%rax  -- the user's signal handler
 *     4. on return, invokes SYS_rt_sigreturn (Linux nr 15). The kernel
 *        side (linux_abi/u_syscalls.ad::_u_rt_sigreturn) reads the
 *        ucontext to restore RIP / RSP / RFLAGS and the pre-handler
 *        signal mask, then SYSRETQs to the interrupted instruction.
 *
 *   Stack alignment: deliver_signal_to_user 16-aligns pop_top. After
 *   the four popq's RSP is at pop_top + 32, still 16-aligned. `callq`
 *   pushes 8 bytes of return-address → RSP%16 == 8 at the handler's
 *   first instruction — exactly what SysV requires.
 *
 *   After the handler returns, RSP is back at pop_top + 32. The
 *   ucontext that rt_sigreturn consults lives ABOVE that — its pointer
 *   was passed in %rdx and the kernel parked a copy of the address it
 *   needs; rt_sigreturn recovers the frame purely from the parked
 *   kstack slots, so the trampoline does not need to preserve %rdx.
 */

    .code64
    .section .text, "ax"

    .align 16
    .globl sig_trampoline
sig_trampoline:
    /* %rdi <- signo (SysV arg 1). */
    popq    %rdi

    /* %rsi <- info_ptr (SysV arg 2 — siginfo_t *). */
    popq    %rsi

    /* %rdx <- uc_ptr (SysV arg 3 — ucontext *). */
    popq    %rdx

    /* %rax <- handler addr. %rax is caller-saved so we may trash it,
     * and `callq *%rax` is one byte shorter than the memory form. */
    popq    %rax

    /* Invoke the user handler: handler(signo, info, ucontext). */
    callq   *%rax

    /* Tail-call into SYS_rt_sigreturn. The kernel side recovers the
     * full rt_sigframe from the parked kstack slots, restores the
     * interrupted RIP / RSP / RFLAGS and the pre-handler signal mask,
     * and rewrites the iret-return slots so SYSRETQ lands back on the
     * interrupted user instruction. We never return through this stub.
     *
     * Linux nr 15 = rt_sigreturn (asm-generic/unistd.h). */
    movq    $15, %rax
    syscall

    /* Unreachable. SYS_rt_sigreturn never returns through this stub —
     * SYSRETQ lands on the interrupted RIP. If something goes wrong
     * (kernel bug), hang to make the failure visible instead of
     * running off into arbitrary user memory. */
.Lsig_tramp_hang:
    jmp     .Lsig_tramp_hang
