/*
 * arch/x86/kernel/trap_asm.S — M16.154-trapdiag.
 *
 * Single-purpose diagnostic for the Asus post-iretq triple-fault.
 *
 * Context (full notes in the M16.154-trapdiag commit message):
 *   On Asus real silicon, `[eft] step2: pre-iretq` prints but
 *   `[eft] step3` does not. So `iretq` executes and then either
 *     (a) iretq itself triple-faults,
 *     (b) iretq succeeds, user's first instruction faults (#GP /
 *         #PF / #UD), exception entry fails  → #DF → triple-fault,
 *     (c) iretq succeeds, user runs briefly, then faults.
 *   A handler that PRINTS for the realistic vectors (#UD, #DF, #GP,
 *   #PF) catches (b) and (c). If nothing prints, it's (a).
 *
 * Layout vs. arch/x86/kernel/idt_asm.S:
 *   - idt_asm.S installs the FIRST 32 vectors at boot via
 *     `trap_stub_0..trap_stub_31 → common_trap → do_trap`. That
 *     handler prints "TRAP: vector 0xNN err=0xNN rip=0xNN" and halts.
 *   - This file adds RICHER stubs for vectors 6, 8, 13, 14 that
 *     additionally print CS, RFLAGS, RSP, SS from the iret frame, and
 *     for vector 8 (#DF) sets IST=1 so the handler runs on a fresh
 *     stack even if the interrupted RSP was wrecked. The IDT entries
 *     for these four vectors are OVERWRITTEN by trap_diag_install()
 *     in arch/x86/kernel/trap_diag.ad — called from init/main.ad
 *     right before start_first_task(), AFTER idt_init() has already
 *     run, so the diag stubs land last and win.
 *
 * Stubs (all live in .text):
 *   trap_diag_stub_06   - #UD, no error code; push 0 then vec 6.
 *   trap_diag_stub_07   - #NM, no error code; push 0 then vec 7.
 *   trap_diag_stub_08   - #DF, error code (always 0 per AMD); push vec 8.
 *   trap_diag_stub_0d   - #GP, error code; push vec 13.
 *   trap_diag_stub_0e   - #PF, error code; push vec 14.
 *   trap_diag_stub_10   - #MF, no error code; push 0 then vec 16.
 *   trap_diag_stub_13   - #XF, no error code; push 0 then vec 19.
 *
 * M16.155-cr0-probe rationale for the new vectors: on Asus real silicon
 * neither IRETQ (M16.154-eft) nor SYSRETQ (M16.155) ring-3 dispatch
 * surfaces a print from the existing #UD/#DF/#GP/#PF handlers. If the
 * first user instruction is an FPU or SIMD op AND CR0.TS=1 or CR0.EM=1,
 * the CPU raises #NM (vector 7) — uninstalled, so it cascades through
 * the boot-stub do_trap path and may not survive whatever made #DF die
 * here. #MF (16, x87 FP error) and #XF (19, SIMD FP exception) are the
 * other two FPU-side faults a first user instruction could trip. With
 * dedicated diag handlers on the same shared IST1 stack we get a print
 * instead of another stair-step into triple-fault.
 *
 * All four jump to common_trap_diag, which:
 *   1. Reads vec / error_code from stack.
 *   2. Reads the 5-quad iret frame (RIP, CS, RFLAGS, RSP, SS).
 *   3. Switches to a dedicated diag call stack so we don't compound
 *      whatever stack-corruption may have driven us here.
 *   4. Calls do_trap_diag_5(vec, err, rip, cs, rflags)   - 5 args fit
 *      in SysV regs (rdi, rsi, rdx, rcx, r8).
 *   5. Calls do_trap_diag_2(rsp, ss).
 *   6. cli; hlt; jmp $ — NO iretq back. This is a one-shot diag.
 *
 * IST stack for #DF:
 *   _trap_diag_ist_stack_top is a 4 KiB .bss buffer; tss_set_ist1
 *   loads its top into TSS.IST1 so the #DF IDT entry (IST=1 bit set
 *   by trap_diag_install) makes the CPU switch to it on entry.
 *
 * Hard constraint: never modify arch/x86/kernel/syscall_64.S. (Not
 * touched — this is a new file with no dependency on syscall path.)
 */

    .code64

/* KPTI: a CPU exception (#UD/#GP/#PF/...) can fire while CPL3 (CR3 = the
 * user PML4); the CPU fetches the stub bytes under that table, so every
 * trap_diag_stub_* AND common_trap_diag live in .kpti.text. The #PF stub
 * (COW) returns to user via iretq and so swaps CR3 back to the user table
 * on the resolved path; the halting diag path swaps to the kernel table
 * on entry (so do_trap_diag can read kernel data) and never returns. */
    .section .kpti.text, "ax"

/* ---------- per-vector stubs ------------------------------------- *
 * Mirror the layout idt_asm.S uses so common_trap_diag can index the
 * post-stub stack identically: vec at 0(%rsp), error_code at 8(%rsp),
 * then the CPU's iret frame at 16(%rsp).                              */

    .align 16
    .globl trap_diag_stub_06
trap_diag_stub_06:
    pushq   $0                          /* fake error code for #UD     */
    pushq   $6
    jmp     common_trap_diag

    .align 16
    .globl trap_diag_stub_07
trap_diag_stub_07:
    /* #NM: device-not-available. No error code; CR0.TS / CR0.EM. */
    pushq   $0                          /* fake error code for #NM     */
    pushq   $7
    jmp     common_trap_diag

    .align 16
    .globl trap_diag_stub_08
trap_diag_stub_08:
    /* #DF: CPU pushes error code (always 0 per AMD64 spec). */
    pushq   $8
    jmp     common_trap_diag

    .align 16
    .globl trap_diag_stub_0d
trap_diag_stub_0d:
    /* #GP: CPU pushes error code (selector + flags). */
    pushq   $13
    jmp     common_trap_diag

/* ---------- trap_diag_stub_0e — productive #PF (copy-on-write) ---- *
 *
 * The #PF vector is no longer a pure diagnostic halt. A write fault to
 * a present, read-only, COW-marked page is a recoverable copy-on-write
 * fault: do_page_fault() copies the page (or just unshares it) and we
 * return to USER with iretq so the faulting instruction re-runs.
 *
 * Any other #PF — a not-present page, a write to a genuinely
 * read-only page, a kernel-mode fault — is a real fault: we fall
 * through to common_trap_diag, preserving the existing print-and-halt
 * behaviour so genuine segfaults are NOT masked.
 *
 * Stack on entry (CPU pushed, low -> high):
 *    0: error_code   (P/W/U/RSVD/I)
 *    8: RIP
 *   16: CS
 *   24: RFLAGS
 *   32: RSP_user
 *   40: SS
 *
 * The COW resolution path must return to the faulting instruction
 * with EVERY register intact, so we save the full GPR set (not just
 * the SysV caller-saved subset) and restore it on the resolved path.
 */
    .align 16
    .globl trap_diag_stub_0e
trap_diag_stub_0e:
    /* Disable interrupts for the whole handler. A COW resolution must
     * be atomic w.r.t. scheduling: if a timer IRQ preempted us
     * mid-resolution, another task could run, take its OWN COW fault,
     * and (before this fix used a global RSP scratch slot) clobber our
     * saved state. cli also means the faulting task cannot be migrated
     * off-CPU between the PTE rewrite and the iretq. The interrupted
     * RFLAGS in the iret frame still has IF=1, so iretq re-enables
     * interrupts on return to the faulting instruction.                */
    cli

    /* #PF: CPU has already pushed the error code at 0(%rsp). Save the
     * full GPR set BELOW it so the resolved path can restore exactly
     * what the faulting instruction expects. 15 GPRs (rsp excluded —
     * it is in the iret frame).                                       */
    pushq   %rax
    pushq   %rbx
    pushq   %rcx
    pushq   %rdx
    pushq   %rsi
    pushq   %rdi
    pushq   %rbp
    pushq   %r8
    pushq   %r9
    pushq   %r10
    pushq   %r11
    pushq   %r12
    pushq   %r13
    pushq   %r14
    pushq   %r15

    /* KPTI: swap CR3 to the kernel table before do_page_fault touches
     * kernel data. A user write to a COW page faults at CPL3 with CR3 =
     * user PML4; a kernel-mode fault arrives with CR3 already kernel
     * (harmless reload). The 15 pushes above are on the kernel stack
     * (PML4[0], mapped in both). %rax/%rcx are saved, use as scratch. */
    leaq    kpti_enabled(%rip), %rax   /* KPTI master switch (skip when OFF */
    movq    (%rax), %rax               /* — CR4.PGE=0, reload = TLB flush) */
    testq   %rax, %rax
    jz      8f
    movq    %gs:0, %rax
    leaq    kpti_kernel_cr3_slots(%rip), %rcx
    movq    (%rcx, %rax, 8), %rax
    testq   %rax, %rax                 /* slot==0 (pre-init)? skip swap */
    jz      8f
    movq    %rax, %cr3
8:

    /* Stack now (low -> high):
     *    0..112: r15..rax  (15 quads)
     *  120: error_code
     *  128: RIP ...                                                    */

    /* do_page_fault(error_code, fault_va, faulting_cr3, iret_frame).
     *   %rdi = error_code   (at 120(%rsp))
     *   %rsi = CR2          (faulting linear address)
     *   %rdx = CR3          (the faulting task's PML4)
     *   %rcx = &iret_frame  (address of the CPU-pushed RIP slot, i.e.
     *                        128(%rsp) at this point: RIP / CS / RFLAGS
     *                        / RSP_user / SS in ascending quads). W^X
     *                        Stage 1a: an NX instruction-fetch SIGSEGV
     *                        is delivered to a USER handler by rewriting
     *                        this frame in place (RIP->trampoline,
     *                        RSP_user->signal frame), so the iretq below
     *                        lands in the handler instead of halting.   */
    movq    120(%rsp), %rdi
    movq    %cr2, %rsi
    movq    %cr3, %rdx
    leaq    128(%rsp), %rcx

    /* Park the pre-call RSP in %rbx — a SysV callee-saved register, so
     * do_page_fault is contractually required to preserve it. (%rbx is
     * already saved on the stack above and gets restored on the way
     * out.) This replaces an earlier global scratch slot that was not
     * re-entrancy / preemption safe. Then 16-align RSP for the call. */
    movq    %rsp, %rbx
    andq    $-16, %rsp
    call    do_page_fault
    /* Restore RSP to the post-push value from the callee-saved %rbx. */
    movq    %rbx, %rsp

    /* do_page_fault returned in %rax:
     *   1  -> COW / demand fault resolved (or a user SIGSEGV handler
     *         was staged into the iret frame); restore GPRs and iretq.
     *   else -> not a recoverable fault (or OOM); fall through to the
     *           diagnostic halt path.                                  */
    cmpq    $1, %rax
    jne     1f

    /* KPTI exit: the fault is resolved and we iretq back to the faulting
     * context. If that context is CPL3 (saved CS RPL == 3 at 136(%rsp):
     * 15 GPRs=120 + ec=8 + RIP=8 -> CS at 136), swap CR3 to the USER
     * table before the pops + iretq. The kernel stack (PML4[0]) and iret
     * frame are mapped in the user table, so the pops resolve post-swap;
     * the iretq fetch is from .kpti.text. A kernel-mode COW fault returns
     * to CPL0 and keeps the kernel table. %rax/%rcx restored by pops. */
    leaq    kpti_enabled(%rip), %rax   /* KPTI master switch (skip when OFF) */
    movq    (%rax), %rax
    testq   %rax, %rax
    jz      2f
    movq    136(%rsp), %rax            /* saved CS */
    andq    $3, %rax
    cmpq    $3, %rax
    jne     2f
    movq    %gs:0, %rax
    leaq    kpti_user_cr3_slots(%rip), %rcx
    movq    (%rcx, %rax, 8), %rax
    movq    %rax, %cr3
2:
    /* Resolved: pop the 15 saved GPRs, drop the error code, iretq. */
    popq    %r15
    popq    %r14
    popq    %r13
    popq    %r12
    popq    %r11
    popq    %r10
    popq    %r9
    popq    %r8
    popq    %rbp
    popq    %rdi
    popq    %rsi
    popq    %rdx
    popq    %rcx
    popq    %rbx
    popq    %rax
    addq    $8, %rsp                    /* discard CPU error code      */
    iretq

1:  /* Not a COW fault. Pop our saved GPRs so the stack is back to the
     * post-CPU-push shape common_trap_diag expects (error_code at
     * 0(%rsp)), then push the vector and take the diagnostic path. */
    popq    %r15
    popq    %r14
    popq    %r13
    popq    %r12
    popq    %r11
    popq    %r10
    popq    %r9
    popq    %r8
    popq    %rbp
    popq    %rdi
    popq    %rsi
    popq    %rdx
    popq    %rcx
    popq    %rbx
    popq    %rax
    pushq   $14
    jmp     common_trap_diag

    .align 16
    .globl trap_diag_stub_10
trap_diag_stub_10:
    /* #MF: x87 floating-point error. No error code. */
    pushq   $0                          /* fake error code for #MF     */
    pushq   $16
    jmp     common_trap_diag

    .align 16
    .globl trap_diag_stub_13
trap_diag_stub_13:
    /* #XF: SIMD floating-point exception. No error code. */
    pushq   $0                          /* fake error code for #XF     */
    pushq   $19
    jmp     common_trap_diag

/* ---------- common_trap_diag ------------------------------------- *
 * Stack on entry (low → high):
 *   0:  vector       (pushed by stub above)
 *   8:  error_code   (pushed by CPU or by stub for #UD)
 *  16:  RIP          (pushed by CPU)
 *  24:  CS
 *  32:  RFLAGS
 *  40:  RSP_user
 *  48:  SS
 *
 * We snapshot all seven values into callee-saved registers (r12..r15
 * + 2 stack slots), swap to a dedicated diag stack, and call the
 * Adder printer. After the print: cli; hlt; never iretq.
 */
    .align 16
    .globl common_trap_diag
common_trap_diag:
    /* KPTI: swap CR3 to the kernel table so do_trap_diag_* can read
     * kernel .rodata / .data. We arrive here from a CPL3 fault with CR3 =
     * user, or from a CPL0 fault with CR3 already kernel (harmless
     * reload). This path HALTS (never iretq), so no exit swap. The vec/ec
     * + iret frame we snapshot below are on the kernel stack (PML4[0],
     * mapped in both). %rax/%rcx are free here (snapshot uses r12..r15 +
     * rbx/rbp). */
    leaq    kpti_enabled(%rip), %rax   /* KPTI master switch (skip when OFF) */
    movq    (%rax), %rax
    testq   %rax, %rax
    jz      9f
    movq    %gs:0, %rax
    leaq    kpti_kernel_cr3_slots(%rip), %rcx
    movq    (%rcx, %rax, 8), %rax
    testq   %rax, %rax                 /* slot==0 (pre-init)? skip swap */
    jz      9f
    movq    %rax, %cr3
9:

    /* Snapshot the seven fields BEFORE we move %rsp. Park them in
     * callee-saved regs so the Adder call can't trash them. We have
     * 5 callee-saved regs available (rbx, rbp, r12, r13, r14, r15
     * — 6 actually). Use r12..r15 + rbx + rbp. We don't need to save
     * the original values; we never return.                            */
    movq    0(%rsp),  %r12              /* vector                     */
    movq    8(%rsp),  %r13              /* error_code                 */
    movq    16(%rsp), %r14              /* RIP                        */
    movq    24(%rsp), %r15              /* CS                         */
    movq    32(%rsp), %rbx              /* RFLAGS                     */
    movq    40(%rsp), %rbp              /* RSP_user                   */
    /* SS is the 7th field — stash into a fixed memory slot so we
     * have all 6 callee-saved regs free for the call shuffle. */
    movq    48(%rsp), %rax
    leaq    _trap_diag_saved_ss(%rip), %rcx
    movq    %rax, (%rcx)

    /* Swap to a dedicated diag call stack. Top-of-stack is the
     * symbol _trap_diag_call_stack_top; we don't care what the
     * interrupted stack contained, that's the whole point of this
     * diag (interrupted stack may be corrupt or in a faulting page). */
    leaq    _trap_diag_call_stack_top(%rip), %rsp

    /* SysV layout:
     *   %rdi = vec   (r12)
     *   %rsi = err   (r13)
     *   %rdx = rip   (r14)
     *   %rcx = cs    (r15)
     *   %r8  = rflags (rbx)
     * 16-byte align before call (mask). We will not return. */
    movq    %r12, %rdi
    movq    %r13, %rsi
    movq    %r14, %rdx
    movq    %r15, %rcx
    movq    %rbx, %r8
    andq    $-16, %rsp
    call    do_trap_diag_5

    /* Second print: rsp_user and ss. Reset stack-top (the call
     * above will have grown it down). */
    leaq    _trap_diag_call_stack_top(%rip), %rsp
    movq    %rbp, %rdi                  /* rsp_user                   */
    leaq    _trap_diag_saved_ss(%rip), %rax
    movq    (%rax), %rsi                /* ss                         */
    andq    $-16, %rsp
    call    do_trap_diag_2

    /* Halt forever. Interrupts off so a stray NMI doesn't perturb
     * the diag-line on a real-hw serial capture. */
    cli
1:  hlt
    jmp     1b

    /* Back to plain .text for the kernel-context helpers below (IDT
     * install lookups + tss_set_ist1; all run with the kernel CR3). */
    .section .text, "ax"

/* ---------- get_trap_diag_stub: dispatch table for IDT install --- *
 * The Adder side calls get_trap_diag_stub(vector) to translate a
 * vector number → handler virtual address, exactly the way idt.ad
 * already calls get_trap_stub() / get_irq_stub() in idt_asm.S /
 * irq_asm.S. Only vectors 6, 7, 8, 13, 14, 16, 19 are wired;
 * anything else returns 0 (caller treats 0 as "skip"). Keeping the
 * lookup in asm means Adder doesn't have to express &symbol
 * arithmetic.                                                          */
    .align 16
    .globl get_trap_diag_stub
get_trap_diag_stub:
    /* %rdi = vector. Return stub address in %rax (or 0). */
    cmpq    $6,  %rdi
    je      1f
    cmpq    $7,  %rdi
    je      5f
    cmpq    $8,  %rdi
    je      2f
    cmpq    $13, %rdi
    je      3f
    cmpq    $14, %rdi
    je      4f
    cmpq    $16, %rdi
    je      6f
    cmpq    $19, %rdi
    je      7f
    xorq    %rax, %rax
    ret
1:  leaq    trap_diag_stub_06(%rip), %rax
    ret
2:  leaq    trap_diag_stub_08(%rip), %rax
    ret
3:  leaq    trap_diag_stub_0d(%rip), %rax
    ret
4:  leaq    trap_diag_stub_0e(%rip), %rax
    ret
5:  leaq    trap_diag_stub_07(%rip), %rax
    ret
6:  leaq    trap_diag_stub_10(%rip), %rax
    ret
7:  leaq    trap_diag_stub_13(%rip), %rax
    ret

/* ---------- get_trap_diag_ist_stack_top -------------------------- *
 * Adder-side helper: returns the top of the IST1 stack so
 * trap_diag_install() can write it into TSS.IST1 via tss_set_ist1.
 * "Top" = highest address; the CPU subtracts BEFORE pushing on entry.
 * (Same convention as tss64.rsp0.)                                     */
    .align 16
    .globl get_trap_diag_ist_stack_top
get_trap_diag_ist_stack_top:
    leaq    _trap_diag_ist_stack_top(%rip), %rax
    ret

/* ---------- tss_set_ist1: install IST1 into the CALLING CPU's TSS  *
 * AMD64 TSS layout (matches tss_asm.S header comment):
 *   offset 0   reserved   (4)
 *   offset 4   RSP0       (8)
 *   offset 12  RSP1       (8)
 *   offset 20  RSP2       (8)
 *   offset 28  reserved   (8)
 *   offset 36  IST1       (8)   ← here
 *   offset 44  IST2       (8)
 *   ...
 * The CPU re-reads TSS.IST1 on the next exception-with-IST entry; no
 * TR reload required (mirrors tss_set_rsp0 in tss_asm.S).
 *
 * Per-CPU: indexes per_cpu_tss[] (in tss_asm.S) by the calling CPU's
 * logical id (cpu_id_pcpu, read via %gs:0 — the codegen pins it to
 * per-CPU offset 0; see setup_percpu_asm.S), so each CPU sets its OWN
 * #DF stack. */
    .equ TSS_STRIDE_TRAP, 128
    .equ NR_TSS_CPUS_TRAP, 16
    .align 16
    .globl tss_set_ist1
tss_set_ist1:
    movq    %gs:0, %rcx                 /* rcx = cpu_id (pinned offset 0) */
    cmpq    $NR_TSS_CPUS_TRAP, %rcx
    jb      1f
    xorq    %rcx, %rcx                  /* clamp bogus id to 0          */
1:  imulq   $TSS_STRIDE_TRAP, %rcx, %rax
    movabsq $per_cpu_tss, %r11
    addq    %r11, %rax                  /* rax = &per_cpu_tss[cpu_id]   */
    movq    %rdi, 36(%rax)              /* TSS.IST1 = arg               */
    ret

/* ---------- BSS storage ------------------------------------------ *
 * KPTI: the #DF IST1 stack is loaded by the CPU when a #DF vectors —
 * which can happen at CPL3 with CR3 = user PML4 — so it MUST be mapped in
 * the user table. Placing all of this file's NOBITS storage in .kpti.bss
 * (mapped in every user PML4) covers that; the call stack + saved_ss are
 * only touched after the kernel-CR3 swap but live here too for locality.
 * .kpti.bss is zeroed by head_64.S. */
    .section .kpti.bss, "aw", @nobits
    .align 16
    .globl _trap_diag_ist_stack_base
_trap_diag_ist_stack_base:
    .skip   4096
    .globl _trap_diag_ist_stack_top
_trap_diag_ist_stack_top:

    .align 16
_trap_diag_call_stack_base:
    .skip   4096
_trap_diag_call_stack_top:

    .align 8
_trap_diag_saved_ss:
    .skip   8
