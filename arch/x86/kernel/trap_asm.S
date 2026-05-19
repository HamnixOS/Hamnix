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
    .section .text, "ax"

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

    .align 16
    .globl trap_diag_stub_0e
trap_diag_stub_0e:
    /* #PF: CPU pushes error code (P/W/U/RSVD/I bits). */
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
 * (Same convention as tss64.rsp0 / _eft_diag_stack_top in
 *  sched_asm.S.)                                                       */
    .align 16
    .globl get_trap_diag_ist_stack_top
get_trap_diag_ist_stack_top:
    leaq    _trap_diag_ist_stack_top(%rip), %rax
    ret

/* ---------- tss_set_ist1: install IST1 into the already-active TSS  *
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
 * TR reload required (mirrors tss_set_rsp0 in tss_asm.S).             */
    .align 16
    .globl tss_set_ist1
tss_set_ist1:
    leaq    tss64(%rip), %rax           /* tss64 lives in tss_asm.S    */
    movq    %rdi, 36(%rax)              /* TSS.IST1 = arg              */
    ret

/* ---------- BSS storage ------------------------------------------ */
    .section .bss
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
