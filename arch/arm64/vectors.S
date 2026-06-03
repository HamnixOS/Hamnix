/*
 * arch/arm64/vectors.S — Phase 3 EL1 exception vector table for Hamnix
 *                        aarch64 on QEMU `virt`.
 *
 * The AArch64 vector table is 0x800 bytes: 16 entries of 0x80 bytes each,
 * grouped in 4 sets of 4 (Synchronous / IRQ / FIQ / SError) for the source
 * exception levels:
 *   0x000 - Current EL with SP_EL0
 *   0x200 - Current EL with SP_ELx   <-- our kernel runs here (EL1h)
 *   0x400 - Lower EL using AArch64
 *   0x600 - Lower EL using AArch32
 *
 * VBAR_EL1 is pointed at `arm64_vectors` (0x800-aligned) by the Adder
 * kernel via the codegen `_install_vbar()` intrinsic. Each entry is padded
 * to 0x80 with `.balign`.
 *
 * The handlers themselves live in PURE ADDER (arch/arm64/kmain.ad): the IRQ
 * stub below saves the caller-clobbered GPR frame, calls the AAPCS64 handler
 * `arm64_irq_handler` (compiled from Adder), restores, and ERETs. Phase 4 adds
 * the "Lower EL using AArch64" Synchronous entry (offset 0x400): an EL0
 * `svc #0` traps to `arm64_lower_sync_entry`, which saves the full x0..x30
 * frame and calls the Adder syscall dispatcher `arm64_sync_handler(frame_ptr)`,
 * then reloads the (mutated) frame and ERETs back to EL0. Current-EL
 * synchronous / unexpected exceptions branch to the Adder diagnostics
 * arm64_sync_panic / arm64_unhandled_panic. This .S file owns ONLY the
 * privileged table layout and the register-frame save/restore that cannot be
 * expressed from Adder.
 */

    .section .text.vectors, "ax"
    .balign 0x800
    .global arm64_vectors
arm64_vectors:

/* ---- Current EL with SP_EL0 (unused here) ---- */
    .balign 0x80
    b       arm64_unhandled         /* Synchronous */
    .balign 0x80
    b       arm64_unhandled         /* IRQ */
    .balign 0x80
    b       arm64_unhandled         /* FIQ */
    .balign 0x80
    b       arm64_unhandled         /* SError */

/* ---- Current EL with SP_ELx (this is where the kernel runs) ---- */
    .balign 0x80
    b       arm64_sync_panic_stub   /* Synchronous (0x200) */
    .balign 0x80
    b       arm64_irq_entry         /* IRQ (0x280) */
    .balign 0x80
    b       arm64_unhandled         /* FIQ (0x300) */
    .balign 0x80
    b       arm64_unhandled         /* SError (0x380) */

/* ---- Lower EL using AArch64 (EL0 userspace traps here) ---- */
    .balign 0x80
    b       arm64_lower_sync_entry  /* Synchronous (0x400): EL0 `svc #0` */
    .balign 0x80
    b       arm64_lower_irq_entry   /* IRQ (0x480): preempt running EL0 task */
    .balign 0x80
    b       arm64_unhandled         /* FIQ (0x500) */
    .balign 0x80
    b       arm64_unhandled         /* SError (0x580) */

/* ---- Lower EL using AArch32 (unused) ---- */
    .balign 0x80
    b       arm64_unhandled
    .balign 0x80
    b       arm64_unhandled
    .balign 0x80
    b       arm64_unhandled
    .balign 0x80
    b       arm64_unhandled

    .balign 0x80

/*
 * IRQ entry stub. Save x0..x18 + x29/x30 (the AAPCS64 caller-saved set plus
 * the link register and frame pointer), call the Adder handler, restore, and
 * ERET. The frame stays 16-byte aligned.
 */
    .text
arm64_irq_entry:
    sub     sp, sp, #(16 * 11)
    stp     x0,  x1,  [sp, #(16 * 0)]
    stp     x2,  x3,  [sp, #(16 * 1)]
    stp     x4,  x5,  [sp, #(16 * 2)]
    stp     x6,  x7,  [sp, #(16 * 3)]
    stp     x8,  x9,  [sp, #(16 * 4)]
    stp     x10, x11, [sp, #(16 * 5)]
    stp     x12, x13, [sp, #(16 * 6)]
    stp     x14, x15, [sp, #(16 * 7)]
    stp     x16, x17, [sp, #(16 * 8)]
    stp     x18, x29, [sp, #(16 * 9)]
    str     x30,      [sp, #(16 * 10)]

    bl      arm64_irq_handler

    ldp     x0,  x1,  [sp, #(16 * 0)]
    ldp     x2,  x3,  [sp, #(16 * 1)]
    ldp     x4,  x5,  [sp, #(16 * 2)]
    ldp     x6,  x7,  [sp, #(16 * 3)]
    ldp     x8,  x9,  [sp, #(16 * 4)]
    ldp     x10, x11, [sp, #(16 * 5)]
    ldp     x12, x13, [sp, #(16 * 6)]
    ldp     x14, x15, [sp, #(16 * 7)]
    ldp     x16, x17, [sp, #(16 * 8)]
    ldp     x18, x29, [sp, #(16 * 9)]
    ldr     x30,      [sp, #(16 * 10)]
    add     sp, sp, #(16 * 11)
    eret

/*
 * Lower-EL (EL0) synchronous entry — the Phase 4 syscall path. An EL0 `svc #0`
 * traps here at EL1h on the kernel's SP_ELx. We save the FULL general-purpose
 * register frame x0..x30 (32 slots, 16-byte aligned) so the Adder syscall
 * dispatcher can read the syscall number (x8) and args (x0..x5) and write the
 * return value back into the x0 slot. The frame base (sp) is passed to the
 * AAPCS64 handler `arm64_sync_handler(frame_ptr)` in x0. On return we reload
 * x0..x30 from the (possibly mutated) frame and ERET back to EL0.
 *
 * Frame layout (offsets in bytes from frame base):
 *   0:x0 8:x1 16:x2 ... 8*n:xn ... 240:x30   (256 bytes total)
 */
arm64_lower_sync_entry:
    sub     sp, sp, #(16 * 16)          /* 32 slots */
    stp     x0,  x1,  [sp, #(16 * 0)]
    stp     x2,  x3,  [sp, #(16 * 1)]
    stp     x4,  x5,  [sp, #(16 * 2)]
    stp     x6,  x7,  [sp, #(16 * 3)]
    stp     x8,  x9,  [sp, #(16 * 4)]
    stp     x10, x11, [sp, #(16 * 5)]
    stp     x12, x13, [sp, #(16 * 6)]
    stp     x14, x15, [sp, #(16 * 7)]
    stp     x16, x17, [sp, #(16 * 8)]
    stp     x18, x19, [sp, #(16 * 9)]
    stp     x20, x21, [sp, #(16 * 10)]
    stp     x22, x23, [sp, #(16 * 11)]
    stp     x24, x25, [sp, #(16 * 12)]
    stp     x26, x27, [sp, #(16 * 13)]
    stp     x28, x29, [sp, #(16 * 14)]
    str     x30,      [sp, #(16 * 15)]

    mov     x0, sp                      /* frame_ptr -> arg0 */
    bl      arm64_sync_handler

    ldp     x0,  x1,  [sp, #(16 * 0)]
    ldp     x2,  x3,  [sp, #(16 * 1)]
    ldp     x4,  x5,  [sp, #(16 * 2)]
    ldp     x6,  x7,  [sp, #(16 * 3)]
    ldp     x8,  x9,  [sp, #(16 * 4)]
    ldp     x10, x11, [sp, #(16 * 5)]
    ldp     x12, x13, [sp, #(16 * 6)]
    ldp     x14, x15, [sp, #(16 * 7)]
    ldp     x16, x17, [sp, #(16 * 8)]
    ldp     x18, x19, [sp, #(16 * 9)]
    ldp     x20, x21, [sp, #(16 * 10)]
    ldp     x22, x23, [sp, #(16 * 11)]
    ldp     x24, x25, [sp, #(16 * 12)]
    ldp     x26, x27, [sp, #(16 * 13)]
    ldp     x28, x29, [sp, #(16 * 14)]
    ldr     x30,      [sp, #(16 * 15)]
    add     sp, sp, #(16 * 16)
    eret

/*
 * Lower-EL (EL0) IRQ entry — the Phase 5 PREEMPTIVE SCHEDULER path. While an
 * EL0 task runs, each generic-timer IRQ traps here at EL1h. We save the FULL
 * interrupted EL0 context (x0..x30 + SP_EL0 + ELR_EL1 + SPSR_EL1) into the
 * *currently running* task's context block, hand that block to the Adder
 * scheduler `arm64_sched_pick(cur_ctx)` which services the tick and returns the
 * NEXT task's context block, then restore that task's full context and ERET
 * into it. This is a real EL0<->EL0 context switch driven by the EL1 timer IRQ.
 *
 * Context block layout (8-byte slots, from base):
 *   0..30 : x0..x30
 *   31    : SP_EL0
 *   32    : ELR_EL1  (resume PC)
 *   33    : SPSR_EL1 (resume PSTATE)
 *
 * The address of the running task's context block is published by the kernel
 * in the global `arm64_current_ctx` before it first erets to EL0; we read it
 * here to know where to save. The scheduler returns the chosen next block and
 * also updates `arm64_current_ctx` itself.
 */
arm64_lower_irq_entry:
    /* Save x0..x30 into the current context block. We need two scratch regs
     * (x0 as the block base, x1 to stage SP_EL0/ELR/SPSR) but must preserve
     * the task's real x0/x1 — so first stash them on the kernel stack. */
    sub     sp, sp, #16
    stp     x0, x1, [sp]                 /* park task x0,x1 on kernel stack */

    ldr     x0, =.Lglobal_arm64_current_ctx
    ldr     x0, [x0]                     /* x0 = &cur_ctx (block base) */

    /* Store x2..x30 directly (their live values are intact). */
    stp     x2,  x3,  [x0, #(8 * 2)]
    stp     x4,  x5,  [x0, #(8 * 4)]
    stp     x6,  x7,  [x0, #(8 * 6)]
    stp     x8,  x9,  [x0, #(8 * 8)]
    stp     x10, x11, [x0, #(8 * 10)]
    stp     x12, x13, [x0, #(8 * 12)]
    stp     x14, x15, [x0, #(8 * 14)]
    stp     x16, x17, [x0, #(8 * 16)]
    stp     x18, x19, [x0, #(8 * 18)]
    stp     x20, x21, [x0, #(8 * 20)]
    stp     x22, x23, [x0, #(8 * 22)]
    stp     x24, x25, [x0, #(8 * 24)]
    stp     x26, x27, [x0, #(8 * 26)]
    stp     x28, x29, [x0, #(8 * 28)]
    str     x30,      [x0, #(8 * 30)]

    /* Recover the task's real x0,x1 from the kernel stack and store them. */
    ldp     x2, x3, [sp]                 /* x2=task x0, x3=task x1 */
    add     sp, sp, #16
    stp     x2, x3, [x0, #(8 * 0)]

    /* Save SP_EL0, ELR_EL1, SPSR_EL1. */
    mrs     x1, sp_el0
    str     x1, [x0, #(8 * 31)]
    mrs     x1, elr_el1
    str     x1, [x0, #(8 * 32)]
    mrs     x1, spsr_el1
    str     x1, [x0, #(8 * 33)]

    /* x0 already = &cur_ctx == arg0; call the Adder scheduler, which acks the
     * IRQ, re-arms the timer, picks the next task, updates arm64_current_ctx,
     * and returns the next task's context block base in x0. */
    bl      arm64_sched_pick

    /* x0 = &next_ctx. Restore SPSR/ELR/SP_EL0 first (x1 scratch). */
    ldr     x1, [x0, #(8 * 33)]
    msr     spsr_el1, x1
    ldr     x1, [x0, #(8 * 32)]
    msr     elr_el1, x1
    ldr     x1, [x0, #(8 * 31)]
    msr     sp_el0, x1

    /* Restore x2..x30, then x0,x1 last (x0 is the block base until then). */
    ldp     x2,  x3,  [x0, #(8 * 2)]
    ldp     x4,  x5,  [x0, #(8 * 4)]
    ldp     x6,  x7,  [x0, #(8 * 6)]
    ldp     x8,  x9,  [x0, #(8 * 8)]
    ldp     x10, x11, [x0, #(8 * 10)]
    ldp     x12, x13, [x0, #(8 * 12)]
    ldp     x14, x15, [x0, #(8 * 14)]
    ldp     x16, x17, [x0, #(8 * 16)]
    ldp     x18, x19, [x0, #(8 * 18)]
    ldp     x20, x21, [x0, #(8 * 20)]
    ldp     x22, x23, [x0, #(8 * 22)]
    ldp     x24, x25, [x0, #(8 * 24)]
    ldp     x26, x27, [x0, #(8 * 26)]
    ldp     x28, x29, [x0, #(8 * 28)]
    ldr     x30,      [x0, #(8 * 30)]
    ldp     x0,  x1,  [x0, #(8 * 0)]
    eret

/*
 * Synchronous exceptions from the current EL and anything unexpected: branch
 * to the Adder diagnostic (which prints a marker and halts in WFI). These
 * never return.
 */
arm64_sync_panic_stub:
    bl      arm64_sync_panic
1:  wfi
    b       1b

arm64_unhandled:
    bl      arm64_unhandled_panic
1:  wfi
    b       1b
