/*
 * arch/x86/kernel/sched_asm.S - context switch primitive.
 *
 * Mirrors the role of __switch_to_asm in
 * arch/x86/entry/entry_64.S (Linux). Saves the SysV AMD64
 * callee-saved register set + %rsp into the outgoing task_struct,
 * loads the same set from the incoming task_struct, and returns. The
 * `ret` at the end pops whatever the new task's stack had at its top
 * as the new RIP — for a freshly-created task that's the kernel
 * thread's entry function (prearranged by kthread_create()); for a
 * task that previously yielded, it's the address right after the
 * `call __switch_to_asm` in schedule().
 *
 * task_struct layout assumed:
 *   offset 0: uint64 sp       (saved stack pointer)
 *   offset 8: uint64 pid      (logical id; not touched here)
 *   ...
 *
 * Callee-saved set on x86-64 SysV ABI: %rbx, %rbp, %r12, %r13, %r14,
 * %r15. We push them in that order; the new task's stack must contain
 * them in the SAME order so the pops line up.
 */

    .code64
    .section .text, "ax"

    .align 16
    .globl __switch_to_asm
__switch_to_asm:
    /* %rdi = prev (current task), %rsi = next (incoming task).
     * task->sp lives at offset 0 of task_struct. */
    pushq   %rbp
    pushq   %rbx
    pushq   %r12
    pushq   %r13
    pushq   %r14
    pushq   %r15

    /* prev->sp = rsp */
    movq    %rsp, 0(%rdi)
    /* rsp = next->sp */
    movq    0(%rsi), %rsp

    popq    %r15
    popq    %r14
    popq    %r13
    popq    %r12
    popq    %rbx
    popq    %rbp
    ret
