/*
 * arch/x86/kernel/sigret_asm.S - U31 user-mode signal trampoline.
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
 *   At trampoline entry, the user stack looks like
 *
 *       (low)  RSP -> signum              <- first quad of our frame
 *              RSP+8 -> handler addr
 *              RSP+16-> saved user RIP
 *              RSP+24-> saved user RFLAGS
 *       (high)
 *
 *   syscall_64.S parks user RSP at (natural_user_rsp - 8) on entry —
 *   the pushq %r12 of the entry stub consumed those 8 bytes — and the
 *   matching popq %r12 at exit lifts RSP back up by 8 before SYSRETQ
 *   resumes user mode. deliver_signal_to_user accounts for that by
 *   writing rsp_slot[0] = frame_top - 8: the final popq %r12 reads
 *   the 8 bytes BELOW our frame (the value loaded into user %r12 is
 *   irrelevant — handlers save R12 themselves per SysV) and RSP ends
 *   up at frame_top with signum at the top of the stack.
 *
 *   On entry:
 *     %rdi: zero (syscall_64.S forces it on the non-FUTEX exit path,
 *           so the signum-in-%rdi convention is restored by the popq
 *           below, NOT inherited from the SYS_kill return slot)
 *     %rsi..%r11: per the SYSRETQ contract — caller-saved, may carry
 *                stale syscall-return scratch values
 *     RFLAGS: 0x202 (IF=1, reserved bit), forced by SYSRETQ
 *
 *   The trampoline:
 *     1. pops signum into %rdi (SysV first arg to the handler)
 *     2. pops the handler addr into %rax
 *     3. calls *%rax  -- the user's signal handler
 *     4. on return, invokes SYS_rt_sigreturn (Linux nr 15). The kernel
 *        side (linux_abi/u_syscalls.ad::_u_rt_sigreturn) restores the
 *        saved RIP/RFLAGS into the iret slot and SYSRETQs to the
 *        original post-kill user instruction.
 *
 *   Stack alignment: SysV requires RSP%16 == 0 at the *call site* of
 *   the handler. The natural user RSP at kill() entry is 16-aligned
 *   (musl's `kill` wrapper does no stack work besides `syscall`), so
 *   `natural - 32` (our frame_top) is still 16-aligned. After the two
 *   popq's RSP is at frame_top + 16, which is 16-aligned. `callq`
 *   pushes 8 bytes of return-address -> RSP%16 == 8 at the entry of
 *   the handler — which is exactly what SysV requires (the called
 *   function sees RSP+8 as 16-aligned).
 */

    .code64
    .section .text, "ax"

    .align 16
    .globl sig_trampoline
sig_trampoline:
    /* %rdi <- signum (SysV first arg). */
    popq    %rdi

    /* %rax <- handler addr. We use %rax because the SysV caller-saved
     * convention lets us trash it freely, and because `callq *%rax`
     * is one byte shorter than the indirect form via memory. */
    popq    %rax

    /* Invoke the user handler. On return, RSP points at the saved-RIP
     * slot (24 bytes into the original frame, 16 bytes after the two
     * pops). */
    callq   *%rax

    /* Tail-call into SYS_rt_sigreturn. The kernel side reads the
     * 16-byte (rip + rflags) restore frame at RSP and rewrites the
     * iret slot in syscall_64.S's parked area so the original
     * post-kill user RIP runs next. We never come back from this
     * syscall — _u_rt_sigreturn drains the frame, fixes up the
     * saved-RIP/RFLAGS in kernel-stack slot kstack_top-24/-16, and
     * returns 0; SYSRETQ then jumps to the rewritten RIP.
     *
     * Linux nr 15 = rt_sigreturn (asm-generic/unistd.h). */
    movq    $15, %rax
    syscall

    /* Unreachable. SYS_rt_sigreturn never returns through this stub —
     * SYSRETQ lands on the original post-kill RIP. If something
     * goes wrong (kernel bug), hang to make the failure visible
     * instead of running off into arbitrary user memory. */
.Lsig_tramp_hang:
    jmp     .Lsig_tramp_hang
