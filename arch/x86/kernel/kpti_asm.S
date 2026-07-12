/*
 * arch/x86/kernel/kpti_asm.S - KPTI (Meltdown) CR3-switch building blocks.
 *
 * These are the low-level primitives a live Kernel Page-Table Isolation
 * trampoline uses to swap between the full kernel CR3 (kernel + user mapped)
 * and the minimal user CR3 (user + entry trampoline only; kernel image
 * stripped). They are the mechanism the follow-up splice into syscall_64.S /
 * irq_asm.S / trap_asm.S will call; see the KPTI design/wall block in
 * arch/x86/kernel/cpu_mitigations.ad for why the live splice is gated
 * (KPTI_LIVE_ENABLE=0) until the entry pages are collected into a mapped
 * cpu_entry_area AND the kernel direct map is relocated out of the
 * user-shared PML4[0].
 *
 * PER-CPU KERNEL-CR3 SLOT
 *   kpti_kernel_cr3 holds the full kernel CR3 value so the entry trampoline
 *   — which runs from the USER CR3 the instant a CPL3->CPL0 transition lands
 *   — can reload the kernel CR3 WITHOUT first dereferencing general kernel
 *   memory. It is read via %gs (the per-CPU base, already valid on entry:
 *   Hamnix sets IA32_GS_BASE directly and never swapgs, so %gs points at the
 *   kernel per-CPU area even at CPL3-entry). For real SMP this must become a
 *   genuine Percpu[uint64] slot; today (-smp 1 first) a single global is
 *   correct and the %gs-less deref below reads it absolutely.
 *
 * VERW-vs-CR3 ORDERING (preserve the MDS mitigation, task #87)
 *   On the EXIT path the order MUST be:
 *       1. VERW mds_verw_sel   (CLEAR_CPU_BUFFERS, while kernel CR3 is live
 *                               and mds_verw_sel is mapped — it lives in
 *                               kernel .rodata, PML4[511], which the user CR3
 *                               strips)
 *       2. switch CR3 -> user
 *       3. SYSRETQ / IRETQ
 *   VERW before the CR3 switch because mds_verw_sel is only guaranteed mapped
 *   under the kernel CR3; doing it after the switch would fault (or, if the
 *   entry window maps it, still works, but keeping VERW first is the robust
 *   invariant). The CR3 write is the last store before the ring transition,
 *   with no kernel-memory access between it and SYSRETQ/IRETQ.
 */

    .code64
    .section .bss
    .align 8
    .globl kpti_kernel_cr3
kpti_kernel_cr3:
    .quad 0

    .section .text, "ax"

/* ---------- kpti_set_kernel_cr3(cr3) ------------------------------- *
 * Publish the full kernel CR3 value into the per-CPU slot the entry
 * trampoline reloads. Called once per CPU after its page tables are up.
 * SysV: %rdi = kernel CR3 physical root (+flags). No return value.        */
    .align 16
    .globl kpti_set_kernel_cr3
kpti_set_kernel_cr3:
    movq    %rdi, kpti_kernel_cr3(%rip)
    ret

/* ---------- kpti_cr3_to_kernel() ----------------------------------- *
 * ENTRY primitive: reload the full kernel CR3 from the per-CPU slot so the
 * rest of the kernel entry path can touch arbitrary kernel memory. Clobbers
 * %rax only. Safe to call the instant a ring transition lands (reads only
 * the kpti_kernel_cr3 slot, which the entry window maps). No-op-safe if the
 * slot is 0 (KPTI not armed) — a 0 CR3 would fault, so the caller gates on
 * kpti_live before invoking this.                                          */
    .align 16
    .globl kpti_cr3_to_kernel
kpti_cr3_to_kernel:
    movq    kpti_kernel_cr3(%rip), %rax
    movq    %rax, %cr3
    ret

/* ---------- kpti_cr3_to_user(user_cr3) ----------------------------- *
 * EXIT primitive: install the minimal user CR3 immediately before the ring
 * transition. MUST be called AFTER the exit-path VERW (mds_verw_sel lives in
 * the kernel image the user CR3 strips) and with NO kernel-memory access
 * between the CR3 write and the following SYSRETQ/IRETQ. SysV: %rdi = the
 * task's user CR3 (from kpti_build_user_pml4, + the PCID/flags the kernel
 * CR3 carried). Clobbers nothing the ABI cares about at an exit boundary.  */
    .align 16
    .globl kpti_cr3_to_user
kpti_cr3_to_user:
    movq    %rdi, %cr3
    ret
